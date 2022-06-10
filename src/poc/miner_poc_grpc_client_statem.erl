-module(miner_poc_grpc_client_statem).
-behavior(gen_statem).
%% tmp disable no match warning from dialyzer
-dialyzer(no_match).
-dialyzer(no_unused).


-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

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
    check_target_req_timer,
    down_events_in_period = 0,
    stability_check_timer,
    block_age_timer
}).

%% these are config vars the miner is interested in, if they change we
%% will want to get their latest values
-define(CONFIG_VARS, ["poc_version", "data_aggregation_version", "poc_timeout", "block_time"]).

%% delay between validator reconnects attempts
-define(VALIDATOR_RECONNECT_DELAY, 5000).
-define(DEFAULT_GRPC_SEND_REPORT_RETRY_DELAY, 30000).
-define(DEFAULT_GRPC_SEND_REPORT_RETRY_ATTEMPTS, 20).
-ifdef(TEST).
%% delay between active check retries
%% these checks determine where to proceed with
%% grpc requests...
-define(ACTIVE_CHECK_DELAY, 1000).
%% interval in seconds at which queued check target reqs are processed
-define(CHECK_TARGET_REQ_DELAY, 5000).
-else.
-define(ACTIVE_CHECK_DELAY, 30000).
-define(CHECK_TARGET_REQ_DELAY, 60000).
-endif.
%% delay between stream reconnects attempts
-define(RECONNECT_DELAY, 5000).
%% Periodic timer to check the stability of our validator connection
%% if we get too many stream disconnects during this period
%% we assume the val is unstable and will connect to a new val
-define(STREAM_STABILITY_CHECK_TIMEOUT, 90000).
%% max number of stream down events  within the STREAM_STABILITY_CHECK_TIMEOUT period
%% after which we will select a new validator
-define(MAX_DOWN_EVENTS_IN_PERIOD, (?STREAM_STABILITY_CHECK_TIMEOUT / ?RECONNECT_DELAY) - 2).
%% Maximum block age returned by a connected validator before triggering an instability reconnect
%% Measured in seconds as this is the unit of time returned by the validator for block_age
-define(MAX_BLOCK_AGE, 600).
-define(BLOCK_AGE_TIMEOUT, ceil(?MAX_BLOCK_AGE / 2) * 1000).
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

-type unary_result() :: {error, any(), map()} | {error, any()} | {ok, any(), map()} | {ok, map()}.
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

-spec send_report(
    ReportType :: witness | receipt,
    Report :: #blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{},
    OnionKeyHash :: binary()) -> ok.
send_report(ReportType, Report, OnionKeyHash) ->
    gen_statem:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash, 
            application:get_env(miner, poc_send_report_retry_attempts, 
                                ?DEFAULT_GRPC_SEND_REPORT_RETRY_ATTEMPTS)}).

-spec send_report(
    ReportType :: witness | receipt,
    Report :: #blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{},
    OnionKeyHash :: binary(),
    Retries :: non_neg_integer()) -> ok.
send_report(ReportType, Report, OnionKeyHash, Retries) ->
    gen_statem:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash, Retries}).

-spec update_config(UpdatedKeys::[string()]) -> ok.
update_config(UpdatedKeys) ->
    gen_statem:cast(?MODULE, {update_config, UpdatedKeys}).

-spec handle_streamed_msg(Msg::any()) -> ok.
handle_streamed_msg(Msg) ->
    gen_statem:cast(?MODULE, {handle_streamed_msg, Msg}).

-spec make_ets_table() -> {ok,atom() | ets:tid()}.
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
    catch erlang:cancel_timer(Data#data.stability_check_timer),
    catch erlang:cancel_timer(Data#data.block_age_timer),
    erlang:send_after(5000, self(), active_check),
    {keep_state, Data#data{
        val_public_ip = undefined,
        val_grpc_port = undefined,
        val_p2p_addr = undefined,
        connection = undefined,
        connection_pid = undefined,
        conn_monitor_ref = undefined
    }};
setup(info, active_check, Data) ->
    %% env var `enable_grpc_client` will have a value of true
    %% if validator challenges are enabled
    %% set from miner lora light
    case application:get_env(miner, enable_grpc_client, false) of
        true ->
            erlang:send_after(?VALIDATOR_RECONNECT_DELAY, self(), find_validator);
        false ->
            erlang:send_after(?ACTIVE_CHECK_DELAY, self(), active_check)
    end,
    {keep_state, Data};
setup(info, find_validator, Data) ->
    %% ask a random seed validator for the address of a 'proper' validator
    %% we will then use this as our default durable validator
    case find_validator() of
        {error, _Reason} ->
            {repeat_state, Data};
        {ok, ValIP, ValPort, ValP2P} ->
            lager:info("*** connecting to validator with ip: ~p, port: ~p, addr: ~p", [
                ValIP, ValPort, ValP2P
            ]),
            {keep_state,
                Data#data{
                    val_public_ip = ValIP,
                    val_grpc_port = ValPort,
                    val_p2p_addr = ValP2P
                },
                [{next_event, info, connect_validator}]};
        _ ->
            {repeat_state, Data}
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
            %% once we have a validator connection established
            %% fire a timer to check how stable the streams are behaving
            SCTRef = erlang:send_after(?STREAM_STABILITY_CHECK_TIMEOUT, self(), stability_check),
            BACTRef = erlang:send_after(block_age_timeout(), self(), block_age_check),
            {keep_state,
                Data#data{
                    connection = Connection,
                    connection_pid = ConnectionPid,
                    conn_monitor_ref = M,
                    stability_check_timer = SCTRef,
                    block_age_timer = BACTRef,
                    down_events_in_period = 0
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
            lager:debug("monitoring stream poc pid ~p with ref ~p", [StreamPid, M]),
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
    lager:warning("got down event ~p", [Event]),
    %% handle down msgs, such as from our streams or validator connection
    %% dont handle it right away, instead wait some time first
    erlang:send_after(?RECONNECT_DELAY, self(), {delayed_down_event, Event}),
    {keep_state, Data};
setup(info, {delayed_down_event, Event}, Data) ->
    handle_down_event(setup, Event, Data);
setup(info, stability_check, Data) ->
    handle_stability_check(setup, Data);
setup(info, block_age_check, Data) ->
    handle_block_age_check(setup, Data);

setup({call, From}, _Msg, Data) ->
    %% return an error for any call msgs whilst in setup state
    {keep_state, Data, [{reply, From, {error, grpc_client_not_ready}}]};
setup(_EventType, _Msg, Data) ->
    %% ignore ev things else whist in setup state
    lager:warning("unhandled event whilst in ~p state: Type: ~p, Msg: ~p", [setup, _EventType, _Msg]),
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
    lager:debug("handle_streamed_msg for msg ~p", [Msg]),
    NewData = do_handle_streamed_msg(Msg, Data),
    {keep_state, NewData};
connected(
    %% Type will be 'cast' when coming from gen_cast
    %% or 'info' when coming from send_after
    Type,
    {send_report, ReportType, Report, OnionKeyHash, RetryAttempts},
    #data{
        connection = Connection,
        self_sig_fun = SelfSigFun,
        self_pub_key_bin = SelfPubKeyBin
    } = Data
) when Type =:= cast; Type =:= info ->
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
    lager:debug("update_config for keys ~p", [Keys]),
    _ = fetch_config(Keys, ValIP, ValPort),
    {keep_state, Data};
connected({call, From}, connection, #data{connection = Connection} = Data) ->
    {keep_state, Data, [{reply, From, {ok, Connection}}]};
connected(info, {'DOWN', _Ref, process, _, _Reason} = Event, Data) ->
    lager:warning("got down event ~p", [Event]),
    %% handle down msgs, such as from our streams or validator connection
    %% dont handle it right away, instead wait some time first
    erlang:send_after(?RECONNECT_DELAY, self(), {delayed_down_event, Event}),
    {keep_state, Data};
connected(info, {delayed_down_event, Event}, Data) ->
    handle_down_event(connected, Event, Data);
connected(info, process_queued_check_target_reqs, Data) ->
    lager:debug("processing queued check_target_reqs", []),
    _ = process_check_target_reqs(Data),
    Ref = erlang:send_after(?CHECK_TARGET_REQ_DELAY, self(), process_queued_check_target_reqs),
    {keep_state, Data#data{check_target_req_timer = Ref}};
connected(info, stability_check, Data) ->
    handle_stability_check(connected, Data);
connected(info, block_age_check, Data) ->
    handle_block_age_check(connected, Data);
connected(_EventType, _Msg, Data) ->
    lager:debug(
        "unhandled event whilst in ~p state: Type: ~p, Msg: ~p",
        [connected, _EventType, _Msg]
    ),
    {keep_state, Data}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec disconnect(Data::data()) -> ok.
disconnect(_Data = #data{connection = undefined}) ->
    ok;
disconnect(_Data = #data{connection = Connection}) ->
    catch grpc_client_custom:stop_connection(Connection),
    ok.

-spec find_validator() -> {ok, string(), pos_integer(), string()} | {error, any()} .
find_validator() ->
    case application:get_env(miner, seed_validators) of
        {ok, SeedValidators} ->
            {_SeedP2PAddr, SeedValIP, SeedValGRPCPort} =
                case lists:nth(rand:uniform(length(SeedValidators)), SeedValidators) of
                    {_SeedP2PAddr0, _SeedValIP0, SeedValGRPCPort0} = AddrAndPort when is_integer(SeedValGRPCPort0) -> AddrAndPort;
                    {_SeedP2PAddr0, SeedValIP0} -> {_SeedP2PAddr0, SeedValIP0, 8080}
                end,
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
                {error, _} = Error ->
                    lager:warning("request to validator failed: ~p", [Error]),
                    {error, Error}
            end;
        _ ->
            lager:warning("failed to find seed validators", []),
            {error, find_validator_request_failed}
    end.

-spec connect_validator(
    ValAddr::string(),
    ValIP::string(),
    ValPort::pos_integer()) ->
    {error, any()} | {ok, grpc_client_custom:connection()}.
connect_validator(ValAddr, ValIP, ValPort) ->
    try
        lager:debug(
            "connecting to validator, p2paddr: ~p, ip: ~p, port: ~p",
            [ValAddr, ValIP, ValPort]
        ),
        case miner_poc_grpc_client_handler:connect(ValAddr, maybe_override_ip(ValIP), ValPort) of
            {error, _Reason} = Error ->
                lager:debug(
                    "failed to connect to validator, will try again in a bit. Reason: ~p",
                    [_Reason]
                ),
                Error;
            {ok, Connection} = Res ->
                Animal = ?TO_ANIMAL_NAME(libp2p_crypto:p2p_to_pubkey_bin(ValAddr)),
                lager:info("successfully connected to validator ~p via connection ~p", [Animal, Connection]),
                Res
        end
    catch
        _Class:_Error:_Stack ->
            lager:warning(
                "error whilst connectting to validator, will try again in a bit. Reason: ~p, Details: ~p, Stack: ~p",
                [_Class, _Error, _Stack]
            ),
            {error, connect_validator_failed}
    end.

-spec connect_stream_poc(
    Connection::grpc_client_custom:connection(),
    SelfPubKeyBin::libp2p_crypto:pubkey_bin(),
    SelfSigFun::function()) ->
        {error, any()} | {ok, pid()}.
connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) ->
    case miner_poc_grpc_client_handler:poc_stream(Connection, SelfPubKeyBin, SelfSigFun) of
        {error, _Reason} = Error ->
            lager:debug("failed to connect to poc stream on connection ~p, reason: ~p", [Connection, _Reason]),
            Error;
        {ok, Stream} = Res ->
            lager:info("successfully connected poc stream ~p on connection ~p", [Stream, Connection]),
            Res
    end.

-spec connect_stream_config_update(
    Connection::grpc_client_custom:connection()) ->
        {error, any()} | {ok, pid()}.
connect_stream_config_update(Connection) ->
   case miner_poc_grpc_client_handler:config_update_stream(Connection) of
        {error, _Reason} = Error ->
            lager:debug("failed to connect to config stream on connection ~p, reason: ~p", [Connection, _Reason]),
            Error;
        {ok, Stream} = Res ->
            lager:info("successfully connected config update stream ~p on connection ~p", [
                Stream, Connection
            ]),
            Res
    end.

-spec connect_stream_region_params_update(
    Connection::grpc_client_custom:connection(),
    SelfPubKeyBin::libp2p_crypto:pubkey_bin(),
    SelfSigFun::function()
) -> {error, any()} | {ok, pid()}.
connect_stream_region_params_update(Connection, SelfPubKeyBin, SelfSigFun) ->
    case
        miner_poc_grpc_client_handler:region_params_update_stream(
            Connection, SelfPubKeyBin, SelfSigFun
        )
    of
        {error, _Reason} = Error ->
            lager:debug("failed to connect to region params update stream on connection ~p, reason: ~p", [Connection, _Reason]),
            Error;
        {ok, Stream} = Res ->
            lager:info(
                "successfully connected region params update stream ~p on connection ~p",
                [Stream, Connection]
            ),
            Res
    end.

-spec send_report(
    ReportType::witness | receipt,
    Report::#blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{},
    OnionKeyHash::binary(),
    SelfPubKeyBin::libp2p_crypto:pubkey_bin(),
    SigFun::function(),
    Connection::grpc_client_custom:connection(),
    RetryAttempts::non_neg_integer()
) -> ok.
send_report(_ReportType, _Report, _OnionKeyHash, _SelfPubKeyBin, _SigFun, _Connection, 0) ->
    lager:warning("failed to submit report.  OnionKeyHash: ~p, Report: ~p", [_OnionKeyHash, _Report]),
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
    Req :: #gateway_poc_report_req_v1_pb{},
    ReportType :: receipt | witness,
    Report :: #blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{},
    OnionKeyHash ::binary(),
    Connection :: grpc_client_custom:connection(),
    RetryAttempts :: non_neg_integer()
) -> ok.
do_send_report(Req, ReportType, Report, OnionKeyHash, Connection, RetryAttempts) ->
    %% ask validator for public uri of the challenger of this POC
    case get_uri_for_challenger(OnionKeyHash, Connection) of
        {ok, {IP, Port}} ->
            %% send the report to our challenger
            case send_grpc_unary_req(IP, Port, Req, 'send_report') of
                {ok, _} ->
                    ok;
                _Error ->
                    lager:debug("send_grpc_unary_req(~p, ~p, ~p, 'send_report') failed with: ~p",
                                [IP,Port,Req,_Error]),
                    retry_report({send_report, ReportType, Report, OnionKeyHash, RetryAttempts - 1})
            end;
        {error, _Reason} ->
            lager:debug("get_uri_for_challenger(~p, ~p) failed with reason: ~p",
                        [OnionKeyHash, Connection, _Reason]),
            retry_report({send_report, ReportType, Report, OnionKeyHash, RetryAttempts - 1})
    end,
    ok.

retry_report(Msg) ->
    RetryDelay = application:get_env(miner, poc_send_report_retry_delay, ?DEFAULT_GRPC_SEND_REPORT_RETRY_DELAY),
    erlang:send_after(RetryDelay, ?MODULE, Msg).

-spec fetch_config(
    UpdatedKeys::[string()],
    ValIP::string(),
    ValGRPCPort::pos_integer()) ->
        {error, any()} | ok.
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

-spec send_grpc_unary_req(
    Connection::grpc_client_custom:connection(),
    Req::tuple(),
    RPC::atom()) -> unary_result().
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
            [{callback_mod, miner_poc_grpc_client_handler},
             {timeout, 10000}]
        ),
        lager:info("send unary result: ~p", [Res]),
        process_unary_response(Res)
    catch
        _Class:_Error:_Stack ->
            lager:warning("send unary failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

-spec send_grpc_unary_req(
    PeerIP :: string(),
    GRPCPort :: non_neg_integer(),
    Req :: tuple(),
    RPC :: atom()) -> unary_result().
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
            [{callback_mod, miner_poc_grpc_client_handler},
             {timeout, 10000}]
        ),
        lager:info("New Connection, send unary result: ~p", [Res]),
        %% we dont need the connection to hang around, so close it out
        catch grpc_client_custom:stop_connection(Connection),
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

-spec build_config_req(Keys::[string()]) -> #gateway_config_req_v1_pb{}.
build_config_req(Keys) ->
    #gateway_config_req_v1_pb{keys = Keys}.

-spec build_poc_challenger_req(OnionKeyHash::binary())
        -> #gateway_poc_key_routing_data_req_v1_pb{}.
build_poc_challenger_req(OnionKeyHash) ->
    #gateway_poc_key_routing_data_req_v1_pb{key = OnionKeyHash}.

-spec build_check_target_req(
    ChallengerPubKeyBin::libp2p_crypto:pubkey_bin(),
    OnionKeyHash::binary(),
    BlockHash::binary(),
    ChallengeHeight::non_neg_integer(),
    ChallengerSig::binary(),
    SelfPubKeyBin::libp2p_crypto:pubkey_bin(),
    SelfSigFun::function()
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

-spec process_unary_response(grpc_client_custom:unary_response()) -> unary_result().
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
process_unary_response({error, _}) ->
    lager:warning("grpc client error response", []),
    {error, req_failed}.

-spec get_uri_for_challenger(
    OnionKeyHash::binary(),
    Connection::grpc_client_custom:connection()) ->
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

-spec process_check_target_reqs(data()) -> ok.
process_check_target_reqs(_State = #data{self_sig_fun = SelfSigFun}) ->
    {ok, POCTimeOut} = application:get_env(miner, poc_timeout),
    {ok, BlockTime} = application:get_env(miner, block_time),
    %% blocktime is in millisecs, convert to secs
    POCTimeOutSecs = (POCTimeOut * (BlockTime / 1000 )),
    CurTSInSecs = erlang:system_time(second),
    Reqs = cached_check_target_reqs(),
    lager:debug("Queued Reqs: ~p",[Reqs]),
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
                        SelfSigFun,
                        true
                    ),
                    ok;
                false ->
                    %% past due on this, remove it from cache
                    lager:debug("removed queued poc from cache with onionkeyhash ~p", [OnionKeyHash]),
                    _ = delete_cached_check_target_req(OnionKeyHash),
                    ok
            end
        end,
        Reqs
    ).

-type target_request_data() :: {
    URI :: string(),
    libp2p_crypto:pubkey_bin(),
    OnionKeyHash :: binary(),
    BlockHash :: binary(),
    NotificationHeight :: non_neg_integer(),
    ChallengerSig :: binary(),
    TimestampSec :: integer()
}.

-spec cache_check_target_req(
    ID :: binary(),
    ReqData :: target_request_data()
) -> true.
cache_check_target_req(ID, ReqData) ->
    true = ets:insert(?CHECK_TARGET_REQS, {ID, ReqData}).

-spec cached_check_target_reqs() -> [tuple()].
cached_check_target_reqs() ->
    ets:tab2list(?CHECK_TARGET_REQS).

-spec delete_cached_check_target_req(Key::binary()) -> ok.
delete_cached_check_target_req(Key) ->
    true = ets:delete(?CHECK_TARGET_REQS, Key),
    ok.

-spec check_if_target(
    URI :: string(),
    PubKeyBin :: binary(),
    OnionKeyHash :: binary(),
    BlockHash :: binary(),
    NotificationHeight :: non_neg_integer(),
    ChallengerSig :: binary(),
    SelfSigFun :: function(),
    IsRetry :: boolean()
) -> ok.
check_if_target(
    URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight,
    ChallengerSig, SelfSigFun, IsRetry
) ->
        TargetRes =
            send_check_target_req(
                URI,
                PubKeyBin,
                OnionKeyHash,
                BlockHash,
                NotificationHeight,
                ChallengerSig,
                SelfSigFun
            ),
        lager:info("check target result for key ~p: ~p, Retry: ~p", [OnionKeyHash, TargetRes, IsRetry]),
        case TargetRes of
            {ok, Result, _Details} ->
                %% we got an expected response, purge req from queued cache should it exist
                _ = delete_cached_check_target_req(OnionKeyHash),
                handle_check_target_resp(Result);
            {error, <<"queued_poc">>, _Details = #{height := ValRespHeight}} ->
                %% seems the POC key exists but the POC itself may not yet be initialised
                %% this can happen if the challenging validator is behind our
                %% notifying validator
                %% if the challenger height is behind or equal
                %% to the notifier, then cache the check target req
                %% and retry it periodically
                N = NotificationHeight - ValRespHeight,
                case (N >= 0) andalso (not IsRetry) of
                    true ->
                        ok = queue_check_target_req(OnionKeyHash, URI, PubKeyBin,
                            BlockHash, NotificationHeight, ChallengerSig),
                        ok;
                    false ->
                        %% eh shouldnt hit here but ok
                        ok
                end;
            {error, _Reason, _Details} ->
                %% we got a non queued response, purge req from queued cache should it exist
                %% these are valid errors, which should not be retried, like mismatched block hash
                _ = delete_cached_check_target_req(OnionKeyHash),
                ok;
            {error, req_failed} ->
                %% the grpc req failed, queue it and try again later
                case (not IsRetry) of
                    true ->
                        ok = queue_check_target_req(OnionKeyHash, URI, PubKeyBin,
                            BlockHash, NotificationHeight, ChallengerSig),
                        ok;
                    false ->
                        %% eh shouldnt hit here but ok
                        ok
                end;
            {error, _Reason} ->
                %% got an error we are not sure what about,
                %% purge req from queued cache should it exist
                _ = delete_cached_check_target_req(OnionKeyHash),
                ok
        end.

-spec send_check_target_req(
    ChallengerURI :: string(),
    ChallengerPubKeyBin :: binary(),
    OnionKeyHash :: binary(),
    BlockHash :: binary(),
    NotificationHeight :: non_neg_integer(),
    ChallengerSig :: binary(),
    SelfSigFun :: function()
) -> unary_result().
send_check_target_req(
    ChallengerURI,
    ChallengerPubKeyBin,
    OnionKeyHash,
    BlockHash,
    NotificationHeight,
    ChallengerSig,
    SelfSigFun
) ->
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    %% split the URI into its IP and port parts
    #{host := IP, port := Port, scheme := _Scheme} =
        uri_string:parse(ChallengerURI),
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

-spec queue_check_target_req(
    OnionKeyHash :: binary(),
    ChallengerURI :: string(),
    PubKeyBin :: binary(),
    BlockHash :: binary(),
    NotificationHeight :: non_neg_integer(),
    ChallengerSig :: binary()
) -> ok.
queue_check_target_req(OnionKeyHash, URI, PubKeyBin, BlockHash, NotificationHeight, ChallengerSig) ->
    CurTSInSecs = erlang:system_time(second),
    _ = cache_check_target_req(
        OnionKeyHash,
        {URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight,
            ChallengerSig, CurTSInSecs}
    ),
    lager:debug("queuing check target request for onionkeyhash ~p with ts ~p", [
        OnionKeyHash, CurTSInSecs
    ]),
    ok.

do_handle_streamed_msg(
    #gateway_resp_v1_pb{
        msg = {poc_challenge_resp, ChallengeNotification},
        height = NotificationHeight,
        signature = ChallengerSig
    } = Msg,
    #data{self_sig_fun = SelfSigFun} = State
) ->
    lager:info("grpc client received gateway_poc_challenge_notification_resp_v1 msg ~p", [Msg]),
    #gateway_poc_challenge_notification_resp_v1_pb{
        challenger = #routing_address_pb{uri = URI, pub_key = PubKeyBin},
        block_hash = BlockHash,
        onion_key_hash = OnionKeyHash
    } = ChallengeNotification,
    _ = check_if_target(
        binary_to_list(URI), PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig, SelfSigFun, false
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
    #gateway_region_params_streamed_resp_v1_pb{
        region = Region,
        params = Params,
        gain = Gain} = Payload,
    #blockchain_region_params_v1_pb{region_params = RegionParams} = Params,
    miner_lora_light:region_params_update(Region, RegionParams),
    miner_onion_server_light:region_params_update(Region, RegionParams, Gain),
    State;
do_handle_streamed_msg(_Msg, State) ->
    lager:warning("grpc client received unexpected streamed msg ~p", [_Msg]),
    State.

handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason},
    Data = #data{conn_monitor_ref = Ref, connection = Connection}
) ->
    lager:warning("GRPC connection to validator is down, reconnecting.  Reason: ~p", [Reason]),
    catch grpc_client_custom:stop_connection(Connection),
    %% if the connection goes down, enter setup state to reconnect
    {next_state, setup, Data#data{connection = undefined}};
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_poc_monitor_ref = Ref,
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun,
        down_events_in_period = NumDownEvents
    }
) when Connection /= undefined ->
    %% the poc stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("poc stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_poc(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{
                stream_poc_monitor_ref = M,
                stream_poc_pid = StreamPid,
                down_events_in_period = NumDownEvents + 1}};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?RECONNECT_DELAY, self(), Event),
            {keep_state, Data#data{down_events_in_period = NumDownEvents + 1}}
    end;
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_config_update_monitor_ref = Ref,
        connection = Connection,
        down_events_in_period = NumDownEvents
    }
) when Connection /= undefined ->
    %% the config_update stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("config_update stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_config_update(Connection) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{
                stream_config_update_monitor_ref = M,
                stream_config_update_pid = StreamPid,
                down_events_in_period = NumDownEvents + 1
            }};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?RECONNECT_DELAY, self(), Event),
            {keep_state, Data#data{down_events_in_period = NumDownEvents + 1}}
    end;
handle_down_event(
    _CurState,
    {'DOWN', Ref, process, _, Reason} = Event,
    Data = #data{
        stream_region_params_update_monitor_ref = Ref,
        connection = Connection,
        self_pub_key_bin = SelfPubKeyBin,
        self_sig_fun = SelfSigFun,
        down_events_in_period = NumDownEvents
    }
) when Connection /= undefined ->
    %% the region_params stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("region_params_update stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    case connect_stream_region_params_update(Connection, SelfPubKeyBin, SelfSigFun) of
        {ok, StreamPid} ->
            M = erlang:monitor(process, StreamPid),
            {keep_state, Data#data{
                stream_region_params_update_monitor_ref = M,
                stream_region_params_update_pid = StreamPid,
                down_events_in_period = NumDownEvents + 1
            }};
        {error, _} ->
            %% if stream reconnnect fails, replay the orig down msg to trigger another attempt
            %% NOTE: not using transition actions below as want a delay before the msgs get processed again
            erlang:send_after(?RECONNECT_DELAY, self(), Event),
            {keep_state, Data#data{down_events_in_period = NumDownEvents + 1}}
    end;
handle_down_event(_CurState, _Event, Data ) ->
    %% fallback handler, if we dont recognise it then ignore it
    %% shouldnt really hit here, but you never know
    lager:warning("unhandled down event: ~p", [_Event]),
    {keep_state, Data}.

handle_stability_check(CurState, Data = #data{down_events_in_period = NumDownEventsThisPeriod}) ->
    case NumDownEventsThisPeriod > ?MAX_DOWN_EVENTS_IN_PERIOD of
        true ->
            Data1 = Data#data{down_events_in_period = 0},
            %% restart the setup state
            case CurState of
                setup ->
                    {repeat_state, Data1};
                _ ->
                    {next_state, setup, Data1}
            end;
        false ->
            %% we have been stable this period, so reset the num of down events
            %% and refire our stability check timer
            TRef = erlang:send_after(?STREAM_STABILITY_CHECK_TIMEOUT, self(), stability_check),
            {keep_state, Data#data{down_events_in_period = 0, stability_check_timer = TRef}}
    end.

handle_block_age_check(_CurState, #data{connection = undefined} = Data) ->
    %% your request for block age cannot be completed at this time; please try again later
    TRef = erlang:send_after(block_age_timeout(), self(), block_age_check),
    {keep_state, Data#data{block_age_timer = TRef}};
handle_block_age_check(CurState, #data{connection = Connection} = Data) ->
    case send_block_age_req(Connection) of
        {ok, BlockAge} when BlockAge >= ?MAX_BLOCK_AGE ->
            %% we're bailing from this validator so reset the down events to start fresh
            Data1 = Data#data{down_events_in_period = 0},
            lager:warning("validator block age ~p exceeded maximum allowed; switching validators", [BlockAge]),
            case CurState of
                setup -> {repeat_state, Data1};
                _ -> {next_state, setup, Data1}
            end;
        {error, _Reason} ->
            %% validator, you had one job...
            Data1 = Data#data{down_events_in_period = 0},
            lager:warning("validator block age request failed for ~p; switching validators", [_Reason]),
            case CurState of
                setup -> {repeat_state, Data1};
                _ -> {next_state, setup, Data1}
            end;
        _ ->
            %% connected validator seems to be keeping up; once more around the loop
            TRef = erlang:send_after(block_age_timeout(), self(), block_age_check),
            {keep_state, Data#data{block_age_timer = TRef}}
    end.

send_block_age_req(Connection) ->
    try
        lager:debug("Send block age unary request", []),
        case grpc_client_custom:unary(
            Connection,
            build_config_req([]),
            'helium.gateway',
            config,
            gateway_miner_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler},
             {timeout, 10000}]
        ) of
            {ok, #{http_status := 200, result := #gateway_resp_v1_pb{block_age = BlockAge}}} when is_integer(BlockAge) ->
                {ok, BlockAge};
            {error, _} ->
                lager:warning("grpc client error requesting current block age"),
                {error, grpc_request_failed}
        end
    catch
        _Class:_Error:_Stack ->
            lager:warning("send block age unary request failed: ~p, ~p, ~p", [_Class, _Error, _Stack]),
            {error, req_failed}
    end.

block_age_timeout() ->
    ?BLOCK_AGE_TIMEOUT + rand:uniform(?BLOCK_AGE_TIMEOUT).

-ifdef(TEST).
maybe_override_ip(_IP) ->
    "127.0.0.1".
-else.
maybe_override_ip(IP) ->
    IP.
-endif.
