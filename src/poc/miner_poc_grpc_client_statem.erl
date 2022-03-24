-module(miner_poc_grpc_client_statem).
-behavior(gen_statem).

%%-dialyzer({nowarn_function, process_unary_response/1}).
%%-dialyzer({nowarn_function, handle_info/2}).
%%-dialyzer({nowarn_function, build_config_req/1}).

-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    stop/0,
    make_ets_table/0,
    connection/0,
    send_report/3,
    send_report/4,
    update_config/1,
    handle_streamed_msg/1
]).

%% ------------------------------------------------------------------
%% gen_statem Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    callback_mode/0,
    terminate/2
]).

%% ------------------------------------------------------------------
%% record defs and macros
%% ------------------------------------------------------------------
-record(data, {
    self_pub_key_bin,
    self_sig_fun,
    connection,
    connection_pid,
    conn_monitor_ref,
    stream_poc_pid,
    stream_poc_monitor_ref,
    stream_config_update_pid,
    stream_config_update_monitor_ref,
    stream_region_params_update_pid,
    stream_region_params_update_monitor_ref,
    val_p2p_addr,
    val_public_ip,
    val_grpc_port,
    check_target_req_timer
}).

%% these are config vars the miner is interested in, if they change we
%% will want to get their latest values
-define(CONFIG_VARS, ["poc_version", "data_aggregation_version", "poc_timeout"]).

%% delay between validator reconnects attempts
-define(VALIDATOR_RECONNECT_DELAY, 5000).
%% delay between stream reconnects attempts
-define(STREAM_RECONNECT_DELAY, 5000).
%% interval in seconds at which queued check target reqs are processed
-define(CHECK_TARGET_REQ_DELAY, 60000).
%% ets table name for check target reqs cache
-define(CHECK_TARGET_REQS, check_target_reqs).
-type data() :: #data{}.

%% ------------------------------------------------------------------
%% gen_statem callbacks Exports
%% ------------------------------------------------------------------
-export([
    setup/3,
    connected/3
]).

%% ------------------------------------------------------------------
%% API Definitions
%% ------------------------------------------------------------------
-spec start_link(#{}) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    case gen_statem:start_link({local, ?MODULE}, ?MODULE, Args, []) of
        {ok, Pid} ->
            %% if we have an ETS table reference, give ownership to the new process
            %% we likely are the `heir', so we'll get it back if this process dies
            %% TODO make table handling better, maybe a list of tables and iterate over
            case maps:find(tab, Args) of
                error ->
                    ok;
                {ok, Tab} ->
                    true = ets:give_away(Tab, Pid, undefined)
            end,
            {ok, Pid};
        Other ->
            Other
    end.

-spec stop() -> ok.
stop() ->
    gen_statem:stop(?MODULE).

-spec connection() -> {ok, grpc_client_custom:connection()}.
connection() ->
    gen_statem:call(?MODULE, connection, infinity).

-spec send_report(witness | receipt, any(), binary()) -> ok.
send_report(ReportType, Report, OnionKeyHash) ->
    gen_statem:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash, 5}).

-spec send_report(witness | receipt, any(), binary(), non_neg_integer()) -> ok.
send_report(ReportType, Report, OnionKeyHash, Retries) ->
    gen_statem:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash, Retries}).

-spec update_config([string()]) -> ok.
update_config(UpdatedKeys) ->
    gen_statem:cast(?MODULE, {update_config, UpdatedKeys}).

-spec handle_streamed_msg(any()) -> ok.
handle_streamed_msg(Msg) ->
    gen_statem:cast(?MODULE, {handle_streamed_msg, Msg}).

-spec make_ets_table() -> [atom()].
make_ets_table() ->
    Tab = ets:new(
        ?CHECK_TARGET_REQS,
        [
            named_table,
            public,
            {heir, self(), undefined}
        ]
    ),
    {ok, Tab}.

%% ------------------------------------------------------------------
%% gen_statem Definitions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("starting ~p", [?MODULE]),
    erlang:process_flag(trap_exit, true),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    {ok, setup, #data{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SigFun}}.

callback_mode() -> [state_functions, state_enter].

terminate(_Reason, Data) ->
    lager:info("terminating with reason ~p", [_Reason]),
    _ = disconnect(Data),
    ok.

%% ------------------------------------------------------------------
%% gen_statem callbacks
%% ------------------------------------------------------------------
setup(enter, _OldState, Data) ->
    %% each time we enter connecting_validator state we assume we are initiating a new
    %% connection to a durable validators
    %% thus ensure all streams are disconnected
    ok = disconnect(Data),
    erlang:send_after(?VALIDATOR_RECONNECT_DELAY, self(), find_validator),
    {keep_state, Data#data{
        val_public_ip = undefined,
        val_grpc_port = undefined,
        val_p2p_addr = undefined
    }};
setup(info, find_validator, Data) ->
    %% ask a random seed validator for the address of a 'proper' validator
    %% we will then use this as our default durable validator
    case find_validator() of
        {error, _Reason} ->
            {repeat_state, Data};
        {ok, ValIP, ValPort, ValP2P} ->
            lager:info("*** Found validator with ip: ~p, port: ~p, addr: ~p", [
                ValIP, ValPort, ValP2P
            ]),
            {keep_state,
                Data#data{
                    val_public_ip = ValIP,
                    val_grpc_port = ValPort,
                    val_p2p_addr = ValP2P
                },
                [{next_event, info, connect_validator}]}
    end;
setup(
    info,
    connect_validator,
    #data{
        val_public_ip = ValIP,
        val_grpc_port = ValGRPCPort,
        val_p2p_addr = ValP2P
    } = Data
) ->
    %% connect to our durable validator
    case connect_validator(ValP2P, ValIP, ValGRPCPort) of
        {ok, Connection} ->
            #{http_connection := ConnectionPid} = Connection,
            M = erlang:monitor(process, ConnectionPid),
            {keep_state,
                Data#data{
                    connection = Connection,
                    connection_pid = ConnectionPid,
                    conn_monitor_ref = M
                },
                [{next_event, info, fetch_config}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(
    info,
    fetch_config,
    #data{
        val_public_ip = ValIP,
        val_grpc_port = ValGRPCPort
    } = Data
) ->
    %% get necessary config data from our durable validator
    case fetch_config(?CONFIG_VARS, ValIP, ValGRPCPort) of
        ok ->
            {keep_state, Data, [{next_event, info, connect_poc_stream}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(
    info,
    connect_poc_stream,
    #data{
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun
    } = Data
) ->
    %% connect any required streams
    %% we are interested in three streams, poc events,  config change events, region params updates
    case connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            lager:info("monitoring stream poc pid ~p with ref ~p", [StreamPid, M]),
            {keep_state,
                Data#data{
                    stream_poc_monitor_ref = M,
                    stream_poc_pid = StreamPid
                },
                [{next_event, info, connect_config_stream}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(
    info,
    connect_config_stream,
    #data{
        connection = Connection
    } = Data
) ->
    %% connect any required streams
    %% we are interested in three streams, poc events,  config change events, region params updates
    case connect_stream_config_update(Connection) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state,
                Data#data{
                    stream_config_update_monitor_ref = M,
                    stream_config_update_pid = StreamPid
                },
                [{next_event, info, connect_region_params_stream}]};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(
    info,
    connect_region_params_stream,
    #data{
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun
    } = Data
) ->
    %% connect any required streams
    %% we are interested in three streams, poc events,  config change events, region params updates
    case connect_stream_region_params_update(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {next_state, connected, Data#data{
                stream_region_params_update_monitor_ref = M,
                stream_region_params_update_pid = StreamPid
            }};
        {error, _} ->
            {repeat_state, Data}
    end;
setup(info, {'DOWN', _Ref, process, _, _Reason} = Event, Data) ->
    lager:info("got down event ~p", [Event]),
    %% handle down msgs, such as from our streams or validator connection
    handle_down_event(setup, Event, Data);
setup({call, From}, _Msg, Data) ->
    %% return an error for any call msgs whilst in setup state
    {keep_state, Data, [{reply, From, {error, grpc_client_not_ready}}]};
setup(_EventType, _Msg, Data) ->
    %% ignore ev things else whist in setup state
    lager:info("unhandled event whilst in ~p state: Type: ~p, Msg: ~p", [setup, _EventType, _Msg]),
    {keep_state, Data}.

connected(enter, _OldState, Data) ->
    %% fire off a timer to periodically process queued check
    %% target requests
    catch erlang:cancel_timer(Data#data.check_target_req_timer),
    Ref = erlang:send_after(
        ?CHECK_TARGET_REQ_DELAY,
        self(),
        process_queued_check_target_reqs
    ),
    {keep_state, Data#data{check_target_req_timer = Ref}};
connected(cast, {handle_streamed_msg, Msg}, #data{} = Data) ->
    lager:info("handle_streamed_msg for msg ~p", [Msg]),
    NewData = do_handle_streamed_msg(Msg, Data),
    {keep_state, NewData};
connected(
    cast,
    {send_report, ReportType, Report, OnionKeyHash, RetryAttempts},
    #data{
        connection = Connection,
        self_sig_fun = SelfSigFun,
        self_pub_key_bin = SelfPubKeyBin
    } = Data
) ->
    lager:info(
        "send_report ~p with onionkeyhash ~p: ~p",
        [ReportType, OnionKeyHash, Report]
    ),
    ok = send_report(
        ReportType,
        Report,
        OnionKeyHash,
        SelfPubKeyBin,
        SelfSigFun,
        Connection,
        RetryAttempts
    ),
    {keep_state, Data};
connected(
    cast,
    {update_config, Keys},
    #data{
        val_public_ip = ValIP,
        val_grpc_port = ValPort
    } = Data
) ->
    lager:info("update_config for keys ~p", [Keys]),
    _ = fetch_config(Keys, ValIP, ValPort),
    {keep_state, Data};
connected({call, From}, connection, #data{connection = Connection} = Data) ->
    {keep_state, Data, [{reply, From, {ok, Connection}}]};
connected(info, {'DOWN', _Ref, process, _, _Reason} = Event, Data) ->
    lager:info("got down event ~p", [Event]),
    %% handle down msgs, such as from our streams or validator connection
    handle_down_event(connected, Event, Data);
connected(info, process_queued_check_target_reqs, Data) ->
    lager:info("processing queued check_target_reqs", []),
    _ = process_check_target_reqs(),
    Ref = erlang:send_after(?CHECK_TARGET_REQ_DELAY, self(), process_queued_check_target_reqs),
    {keep_state, Data#data{check_target_req_timer = Ref}};
connected(_EventType, _Msg, Data) ->
    lager:info(
        "unhandled event whilst in ~p state: Type: ~p, Msg: ~p",
        [connected, _EventType, _Msg]
    ),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec disconnect(data()) -> ok.
disconnect(_Data = #data{connection = undefined}) ->
    ok;
disconnect(_Data = #data{connection = Connection}) ->
    catch _ = grpc_client_custom:stop_connection(Connection),
    ok.

-spec find_validator() -> {error, any()} | {ok, string(), pos_integer(), string()}.
find_validator() ->
    case application:get_env(miner, seed_validators) of
        {ok, SeedValidators} ->
            {_SeedP2PAddr, SeedValIP, SeedValGRPCPort} =
                lists:nth(rand:uniform(length(SeedValidators)), SeedValidators),
            Req = build_validators_req(1),
            case send_grpc_unary_req(SeedValIP, SeedValGRPCPort, Req, 'validators') of
                {ok, #gateway_validators_resp_v1_pb{result = []}, _ReqDetails} ->
                    %% no routes, retry in a bit
                    lager:warning("failed to find any validator routing from seed validator ~p", [
                        SeedValIP
                    ]),
                    {error, no_validators};
                {ok, #gateway_validators_resp_v1_pb{result = Routing}, _ReqDetails} ->
                    %% resp will contain the payload 'gateway_validators_resp_v1_pb'
                    [
                        #routing_address_pb{
                            pub_key = DurableValPubKeyBin,
                            uri = DurableValURI
                        }
                    ] = Routing,
                    DurableValP2PAddr =
                        libp2p_crypto:pubkey_bin_to_p2p(DurableValPubKeyBin),
                    #{
                        host := DurableValIP,
                        port := DurableValGRPCPort
                    } =
                        uri_string:parse(binary_to_list(DurableValURI)),
                    {ok, DurableValIP, DurableValGRPCPort, DurableValP2PAddr};
                {error, Reason} = _Error ->
                    lager:warning("request to validator failed: ~p", [_Error]),
                    {error, Reason}
            end;
        _ ->
            lager:warning("failed to find seed validators", []),
            {error, find_validator_request_failed}
    end.

-spec connect_validator(string(), string(), pos_integer()) ->
    {error, any()} | {ok, grpc_client_custom:connection()}.
connect_validator(ValAddr, ValIP, ValPort) ->
    try
        lager:info(
            "connecting to validator, p2paddr: ~p, ip: ~p, port: ~p",
            [ValAddr, ValIP, ValPort]
        ),
        case miner_poc_grpc_client_handler:connect(ValAddr, maybe_override_ip(ValIP), ValPort) of
            {error, _} = Error ->
                Error;
            {ok, Connection} = Res ->
                lager:info("successfully connected to validator via connection ~p", [Connection]),
                Res
        end
    catch
        _Class:_Error:_Stack ->
            lager:info(
                "failed to connect to validator, will try again in a bit. Reason: ~p, Details: ~p, Stack: ~p",
                [_Class, _Error, _Stack]
            ),
            {error, connect_validator_failed}
    end.

-spec connect_stream_poc(grpc_client_custom:connection(), libp2p_crypto:pubkey_bin(), function()) ->
    {error, any()} | {ok, pid()}.
connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) ->
    lager:info("establishing POC stream on connection ~p", [Connection]),
    case miner_poc_grpc_client_handler:poc_stream(Connection, SelfPubKeyBin, SelfSigFun) of
        {error, _Reason} = Error ->
            Error;
        {ok, Stream} = Res ->
            lager:info("successfully connected poc stream ~p on connection ~p", [Stream, Connection]),
            Res
    end.

-spec connect_stream_config_update(grpc_client_custom:connection()) ->
    {error, any()} | {ok, pid()}.
connect_stream_config_update(Connection) ->
    lager:info("establishing config_update stream on connection ~p", [Connection]),
    case miner_poc_grpc_client_handler:config_update_stream(Connection) of
        {error, _Reason} = Error ->
            Error;
        {ok, Stream} = Res ->
            lager:info("successfully connected config update stream ~p on connection ~p", [
                Stream, Connection
            ]),
            Res
    end.

-spec connect_stream_region_params_update(
    grpc_client_custom:connection(),
    libp2p_crypto:pubkey_bin(),
    function()
) -> {error, any()} | {ok, pid()}.
connect_stream_region_params_update(Connection, SelfPubKeyBin, SelfSigFun) ->
    lager:info("establishing region_params_update stream on connection ~p", [Connection]),
    case
        miner_poc_grpc_client_handler:region_params_update_stream(
            Connection, SelfPubKeyBin, SelfSigFun
        )
    of
        {error, _Reason} = Error ->
            Error;
        {ok, Stream} = Res ->
            lager:info(
                "successfully connected region params update stream ~p on connection ~p",
                [Stream, Connection]
            ),
            Res
    end.

-spec send_report(
    witness | receipt,
    any(),
    binary(),
    libp2p_crypto:pubkey_bin(),
    function(),
    grpc_client_custom:connection(),
    non_neg_integer()
) -> ok.
send_report(_ReportType, _Report, _OnionKeyHash, _SelfPubKeyBin, _SigFun, _Connection, 0) ->
    ok;
send_report(
    receipt = ReportType, Report, OnionKeyHash, _SelfPubKeyBin, SigFun, Connection, RetryAttempts
) ->
    EncodedReceipt = gateway_miner_client_pb:encode_msg(
        Report#blockchain_poc_receipt_v1_pb{signature = <<>>}, blockchain_poc_receipt_v1_pb
    ),
    SignedReceipt = Report#blockchain_poc_receipt_v1_pb{signature = SigFun(EncodedReceipt)},
    Req = #gateway_poc_report_req_v1_pb{
        onion_key_hash = OnionKeyHash,
        msg = {ReportType, SignedReceipt}
    },
    do_send_report(Req, ReportType, Report, OnionKeyHash, Connection, RetryAttempts);
send_report(
    witness = ReportType, Report, OnionKeyHash, _SelfPubKeyBin, SigFun, Connection, RetryAttempts
) ->
    EncodedWitness = gateway_miner_client_pb:encode_msg(
        Report#blockchain_poc_witness_v1_pb{signature = <<>>}, blockchain_poc_witness_v1_pb
    ),
    SignedWitness = Report#blockchain_poc_witness_v1_pb{signature = SigFun(EncodedWitness)},
    Req = #gateway_poc_report_req_v1_pb{
        onion_key_hash = OnionKeyHash,
        msg = {ReportType, SignedWitness}
    },
    do_send_report(Req, ReportType, Report, OnionKeyHash, Connection, RetryAttempts).

-spec do_send_report(
    binary(), witness | receipt, any(), binary(), grpc_client_custom:connection(), non_neg_integer()
) -> ok.
do_send_report(Req, ReportType, Report, OnionKeyHash, Connection, RetryAttempts) ->
    %% ask validator for public uri of the challenger of this POC
    case get_uri_for_challenger(OnionKeyHash, Connection) of
        {ok, {IP, Port}} ->
            %% send the report to our challenger
            case send_grpc_unary_req(IP, Port, Req, 'send_report') of
                {ok, _} ->
                    ok;
                _ ->
                    ?MODULE:send_report(ReportType, Report, OnionKeyHash, RetryAttempts - 1)
            end;
        {error, _Reason} ->
            ?MODULE:send_report(ReportType, Report, OnionKeyHash, RetryAttempts - 1)
    end,
    ok.

-spec fetch_config([string()], string(), pos_integer()) -> {error, any()} | ok.
fetch_config(UpdatedKeys, ValIP, ValGRPCPort) ->
    %% filter out keys we are not interested in
    %% and then ask our validator for current values
    %% for remaining keys
    FilteredKeys = lists:filter(fun(K) -> lists:member(K, ?CONFIG_VARS) end, UpdatedKeys),
    case FilteredKeys of
        [] ->
            ok;
        _ ->
            %% retrieve some config from the returned validator
            Req2 = build_config_req(FilteredKeys),
            case send_grpc_unary_req(ValIP, ValGRPCPort, Req2, 'config') of
                {ok, #gateway_config_resp_v1_pb{result = Vars}, _Req2Details} ->
                    [
                        begin
                            {Name, Value} = blockchain_txn_vars_v1:from_var(Var),
                            application:set_env(miner, list_to_atom(Name), Value)
                        end
                     || #blockchain_var_v1_pb{} = Var <- Vars
                    ],
                    ok;
                {error, Reason, _Details} ->
                    {error, Reason};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec send_grpc_unary_req(grpc_client_custom:connection(), any(), atom()) ->
    {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
send_grpc_unary_req(undefined, _Req, _RPC) ->
    {error, no_grpc_connection};
send_grpc_unary_req(Connection, Req, RPC) ->
    try
        lager:info("send unary request: ~p", [Req]),
        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_miner_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("send unary result: ~p", [Res]),
        process_unary_response(Res)
    catch
        _Class:_Error:_Stack ->
            lager:warning("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

-spec send_grpc_unary_req(string(), non_neg_integer(), any(), atom()) ->
    {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
send_grpc_unary_req(PeerIP, GRPCPort, Req, RPC) ->
    try
        lager:info("Send unary request via new connection to ip ~p: ~p", [PeerIP, Req]),
        {ok, Connection} = grpc_client_custom:connect(tcp, maybe_override_ip(PeerIP), GRPCPort),

        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_miner_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("New Connection, send unary result: ~p", [Res]),
        %% we dont need the connection to hang around, so close it out
        catch _ = grpc_client_custom:stop_connection(Connection),
        process_unary_response(Res)
    catch
        _Class:_Error:_Stack ->
            lager:warning("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

-spec build_validators_req(Quantity :: pos_integer()) -> #gateway_validators_req_v1_pb{}.
build_validators_req(Quantity) ->
    #gateway_validators_req_v1_pb{
        quantity = Quantity
    }.

-spec build_config_req([string()]) -> #gateway_config_req_v1_pb{}.
build_config_req(Keys) ->
    #gateway_config_req_v1_pb{keys = Keys}.

-spec build_poc_challenger_req(binary()) -> #gateway_poc_key_routing_data_req_v1_pb{}.
build_poc_challenger_req(OnionKeyHash) ->
    #gateway_poc_key_routing_data_req_v1_pb{key = OnionKeyHash}.

-spec build_check_target_req(
    libp2p_crypto:pubkey_bin(),
    binary(),
    binary(),
    non_neg_integer(),
    binary(),
    libp2p_crypto:pubkey_bin(),
    function()
) -> #gateway_poc_check_challenge_target_req_v1_pb{}.
build_check_target_req(
    ChallengerPubKeyBin,
    OnionKeyHash,
    BlockHash,
    ChallengeHeight,
    ChallengerSig,
    SelfPubKeyBin,
    SelfSigFun
) ->
    Req = #gateway_poc_check_challenge_target_req_v1_pb{
        address = SelfPubKeyBin,
        challenger = ChallengerPubKeyBin,
        block_hash = BlockHash,
        onion_key_hash = OnionKeyHash,
        height = ChallengeHeight,
        notifier = ChallengerPubKeyBin,
        notifier_sig = ChallengerSig,
        challengee_sig = <<>>
    },
    ReqEncoded = gateway_miner_client_pb:encode_msg(
        Req, gateway_poc_check_challenge_target_req_v1_pb
    ),
    Req#gateway_poc_check_challenge_target_req_v1_pb{challengee_sig = SelfSigFun(ReqEncoded)}.

%% TODO: return a better and consistent response
%%-spec process_unary_response(grpc_client_custom:unary_response()) -> {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
process_unary_response(
    {ok, #{
        http_status := 200,
        result := #gateway_resp_v1_pb{
            msg = {success_resp, _Payload}, height = Height, signature = Sig
        }
    }}
) ->
    {ok, #{height => Height, signature => Sig}};
process_unary_response(
    {ok, #{
        http_status := 200,
        result := #gateway_resp_v1_pb{msg = {error_resp, Details}, height = Height, signature = Sig}
    }}
) ->
    #gateway_error_resp_pb{error = ErrorReason} = Details,
    {error, ErrorReason, #{height => Height, signature => Sig}};
process_unary_response(
    {ok, #{
        http_status := 200,
        result := #gateway_resp_v1_pb{msg = {_RespType, Payload}, height = Height, signature = Sig}
    }}
) ->
    {ok, Payload, #{height => Height, signature => Sig}};
process_unary_response({error, ClientError = #{error_type := 'client'}}) ->
    lager:warning("grpc error response ~p", [ClientError]),
    {error, grpc_client_error};
process_unary_response(
    {error, ClientError = #{error_type := 'grpc', http_status := 200, status_message := ErrorMsg}}
) ->
    lager:warning("grpc error response ~p", [ClientError]),
    {error, ErrorMsg};
process_unary_response(_Response) ->
    lager:warning("unhandled grpc response ~p", [_Response]),
    {error, unexpected_response}.

handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason},
    Data = #data{conn_monitor_ref = Ref, connection = Connection}
) ->
    lager:warning("GRPC connection to validator is down, reconnecting.  Reason: ~p", [Reason]),
    _ = grpc_client_custom:stop_connection(Connection),
    %% if the connection goes down, enter setup state to reconnect
    {next_state, setup, Data};
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_poc_monitor_ref = Ref,
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun
    }
) ->
    %% the poc stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("poc stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{stream_poc_monitor_ref = M, stream_poc_pid = StreamPid}};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?STREAM_RECONNECT_DELAY, self(), Event),
            {keep_state, Data}
    end;
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_config_update_monitor_ref = Ref,
        connection = Connection
    }
) ->
    %% the config_update stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("config_update stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_config_update(Connection) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{
                stream_config_update_monitor_ref = M, stream_config_update_pid = StreamPid
            }};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?STREAM_RECONNECT_DELAY, self(), Event),
            {keep_state, Data}
    end;
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_region_params_update_monitor_ref = Ref,
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun
    }
) ->
    %% the region_params stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("region_params_update stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_region_params_update(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{
                stream_region_params_update_monitor_ref = M, stream_region_params_update_pid = StreamPid
            }};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?STREAM_RECONNECT_DELAY, self(), Event),
            {keep_state, Data}
    end.

-spec get_uri_for_challenger(binary(), grpc_client_custom:connection()) ->
    {ok, {string(), pos_integer()}} | {error, any()}.
get_uri_for_challenger(OnionKeyHash, Connection) ->
    Req = build_poc_challenger_req(OnionKeyHash),
    case send_grpc_unary_req(Connection, Req, 'poc_key_to_public_uri') of
        {ok, #gateway_public_routing_data_resp_v1_pb{public_uri = URIData}, _Req2Details} ->
            #routing_address_pb{uri = URI, pub_key = _PubKey} = URIData,
            #{host := IP, port := Port} = uri_string:parse(binary_to_list(URI)),
            {ok, {IP, Port}};
        {error, Reason, _Details} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_check_target_reqs() -> ok.
process_check_target_reqs() ->
    {ok, POCTimeOut} = application:get_env(miner, poc_timeout),
    %% convert poc timeout in blocks to equiv in seconds
    %% use to determine when the POC would end
    %% if the cached request has remained in the cache
    %% for 80% of the timeout period, then give up on it & remove
    %% we use 80% as we need to give the POC time to run,
    %% no point getting the onion and broadcasting if no time
    %% left for it to complete
    POCTimeOutSecs = (POCTimeOut * 0.8 * 60),
    CurTSInSecs = erlang:system_time(second),
    Reqs = cached_check_target_reqs(),
    lager:info("Queued Reqs: ~p",[Reqs]),
    lists:foreach(
        fun(
            {_Key, {ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight,
                ChallengerSig, QueueEnterTSInSecs}}
        ) ->
            case CurTSInSecs < (QueueEnterTSInSecs + POCTimeOutSecs) of
                true ->
                    %% time to retry the request
                    _ = check_if_target(
                        ChallengerURI,
                        ChallengerPubKeyBin,
                        OnionKeyHash,
                        BlockHash,
                        NotificationHeight,
                        ChallengerSig,
                        true
                    ),
                    ok;
                false ->
                    %% past due on this, remove it from cache
                    lager:info("removed queued poc from cache with onionkeyhash ~p", [OnionKeyHash]),
                    _ = delete_cached_check_target_req(OnionKeyHash),
                    ok
            end
        end,
        Reqs
    ).

-spec cache_check_target_req(
    binary(),
    {
        string(),
        libp2p_crypto:pubkey_bin(),
        binary(),
        binary(),
        pos_integer(),
        function(),
        integer()
    }
) -> true.
cache_check_target_req(ID, ReqData) ->
    true = ets:insert(?CHECK_TARGET_REQS, {ID, ReqData}).

-spec cached_check_target_reqs() -> [tuple()].
cached_check_target_reqs() ->
    ets:tab2list(?CHECK_TARGET_REQS).

-spec delete_cached_check_target_req(binary()) -> ok.
delete_cached_check_target_req(Key) ->
    true = ets:delete(?CHECK_TARGET_REQS, Key),
    ok.

-spec is_queued_check_target_req(binary()) -> boolean().
is_queued_check_target_req(OnionKeyHash) ->
    ets:member(?CHECK_TARGET_REQS, OnionKeyHash).

do_handle_streamed_msg(
    #gateway_resp_v1_pb{
        msg = {poc_challenge_resp, ChallengeNotification},
        height = NotificationHeight,
        signature = ChallengerSig
    } = Msg,
    State
) ->
    lager:info("grpc client received gateway_poc_challenge_notification_resp_v1 msg ~p", [Msg]),
    #gateway_poc_challenge_notification_resp_v1_pb{
        challenger = #routing_address_pb{uri = URI, pub_key = PubKeyBin},
        block_hash = BlockHash,
        onion_key_hash = OnionKeyHash
    } = ChallengeNotification,
    _ = check_if_target(
        URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig, false
    ),
    State;
do_handle_streamed_msg(
    #gateway_resp_v1_pb{
        msg = {config_update_streamed_resp, Payload},
        height = _NotificationHeight,
        signature = _ChallengerSig
    } = _Msg,
    State
) ->
    lager:info("grpc client received config_update_streamed_resp msg ~p", [_Msg]),
    #gateway_config_update_streamed_resp_v1_pb{keys = UpdatedKeys} = Payload,
    _ = miner_poc_grpc_client_statem:update_config(UpdatedKeys),
    State;
do_handle_streamed_msg(
    #gateway_resp_v1_pb{
        msg = {region_params_streamed_resp, Payload},
        height = _NotificationHeight,
        signature = _ChallengerSig
    } = _Msg,
    State
) ->
    lager:info("grpc client received region_params_streamed_resp msg ~p", [_Msg]),
    #gateway_region_params_streamed_resp_v1_pb{region = Region, params = Params} = Payload,
    #blockchain_region_params_v1_pb{region_params = RegionParams} = Params,
    miner_lora_light:region_params_update(Region, RegionParams),
    miner_onion_server_light:region_params_update(Region, RegionParams),
    State;
do_handle_streamed_msg(_Msg, State) ->
    lager:info("grpc client received unexpected streamed msg ~p", [_Msg]),
    State.

-spec check_if_target(
    string(),
    libp2p_crypto:pubkey_bin(),
    binary(),
    binary(),
    pos_integer(),
    function(),
    boolean()
) -> ok.
check_if_target(
    URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig, IsRetry
) ->
    F = fun() ->
        TargetRes =
            send_check_target_req(
                URI,
                PubKeyBin,
                OnionKeyHash,
                BlockHash,
                NotificationHeight,
                ChallengerSig
            ),
        lager:info("check target result for key ~p: ~p, Retry: ~p", [OnionKeyHash, TargetRes, IsRetry]),
        case TargetRes of
            {ok, Result, _Details} ->
                %% we got an expected response, purge req from queued cache should it exist
                _ = delete_cached_check_target_req(OnionKeyHash),
                handle_check_target_resp(Result);
            {error, <<"queued_poc">>, #{height := ValRespHeight} = _Details} ->
                %% seems the POC key exists but the POC itself may not yet be initialised
                %% this can happen if the challenging validator is behind our
                %% notifying validator
                %% if the challenger is behind the notifier, then add cache the check target req
                %% it will then be retried periodically
                N = NotificationHeight - ValRespHeight,
                case (N > 0) andalso (not IsRetry) of
                    true ->
                        CurTSInSecs = erlang:system_time(second),
                        _ = cache_check_target_req(
                            OnionKeyHash,
                            {URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight,
                                ChallengerSig, CurTSInSecs}
                        ),
                        lager:info("queuing check target request for onionkeyhash ~p with ts ~p", [
                            OnionKeyHash, CurTSInSecs
                        ]),
                        ok;
                    false ->
                        %% eh shouldnt hit here but ok
                        ok
                end;
            {error, _Reason, _Details} ->
                %% we got an non queued response, purge req from queued cache should it exist
                _ = delete_cached_check_target_req(OnionKeyHash),
                ok;
            {error, _Reason} ->
                ok
        end
    end,
    spawn(F).

-spec send_check_target_req(
    string(),
    libp2p_crypto:pubkey_bin(),
    binary(),
    binary(),
    non_neg_integer(),
    libp2p_crypto:signature()
) -> {error, any()} | {error, any(), map()} | {ok, any(), map()}.
send_check_target_req(
    ChallengerURI,
    ChallengerPubKeyBin,
    OnionKeyHash,
    BlockHash,
    NotificationHeight,
    ChallengerSig
) ->
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SelfSigFun, _} = blockchain_swarm:keys(),
    %% split the URI into its IP and port parts
    #{host := IP, port := Port, scheme := _Scheme} =
        uri_string:parse(binary_to_list(ChallengerURI)),
    TargetIP = maybe_override_ip(IP),
    %% build the request
    Req = build_check_target_req(
        ChallengerPubKeyBin,
        OnionKeyHash,
        BlockHash,
        NotificationHeight,
        ChallengerSig,
        SelfPubKeyBin,
        SelfSigFun
    ),
    send_grpc_unary_req(TargetIP, Port, Req, 'check_challenge_target').

-spec handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{}) -> ok.
handle_check_target_resp(
    #gateway_poc_check_challenge_target_resp_v1_pb{target = true, onion = Onion} = _ChallengeResp
) ->
    ok = miner_onion_server_light:decrypt_p2p(Onion);
handle_check_target_resp(
    #gateway_poc_check_challenge_target_resp_v1_pb{target = false} = _ChallengeResp
) ->
    ok.

-ifdef(TEST).
maybe_override_ip(_IP) ->
    "127.0.0.1".
-else.
maybe_override_ip(IP) ->
    IP.
-endif.
