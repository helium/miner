%%%-------------------------------------------------------------------
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_grpc_client).

-behaviour(gen_server).
-include("src/grpc/autogen/client/gateway_client_pb.hrl").
-include_lib("public_key/include/public_key.hrl").

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    connection/0,
    check_target/6,
    send_report/3,
    region_params/0
]).
%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ------------------------------------------------------------------
%% record defs and macros
%% ------------------------------------------------------------------

-record(state, {
    self_pub_key_bin,
    self_sig_fun,
    connection,
    connection_pid,
    stream_pid,
    conn_monitor_ref,
    stream_monitor_ref,
    validator_p2p_addr,
    validator_public_ip,
    validator_grpc_port
}).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

connection() ->
    gen_server:call(?MODULE, connection, infinity).

region_params() ->
    gen_server:call(?MODULE, region_params, infinity).

check_target(ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig) ->
    gen_server:cast(?MODULE, {check_target, ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig}).

send_report(ReportType, Report, OnionKeyHash)->
    gen_server:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash}).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("starting ~p", [?MODULE]),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    erlang:send_after(500, self(), connect_grpc),
    {ok, #state{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SigFun}}.

handle_call(connection, _From, State = #state{connection = Connection}) ->
    {reply, {ok, Connection}, State};
handle_call(region_params, _From, State = #state{self_pub_key_bin = Addr, self_sig_fun = SigFun, connection = Connection}) ->
    Req = build_region_params_req(Addr, SigFun),
    Resp = send_grpc_unary_req(Connection, Req, 'region_params'),
    {reply, Resp, State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast({check_target, ChallengerURI, ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig}, #state{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = State) ->
    %% split the URI into its IP and port parts
    #{host := _IP, port := Port, scheme := _Scheme} = uri_string:parse(ChallengerURI),
    %% build the request
    Req = build_check_target_req(ChallengerPubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig, SelfPubKeyBin, SelfSigFun),
    case send_grpc_unary_req("127.0.0.1", Port, Req, 'check_challenge_target') of
        {ok, Resp, #{height := ResponseHeight, signature := ResponseSig} = _Details} ->
            lager:info("checked target results ~p", [Resp]),
            %% handle the result as to if we are the target or not
            ok = handle_check_target_resp(Resp, ResponseHeight, ResponseSig);
        {grpc_error, Reason} ->
            lager:error("failed to check target.  URI: ~p, reason: ~p", [ChallengerURI, Reason]),
            ok;
        {error, Reason, _} ->
            lager:error("failed to check target.  URI: ~p, reason: ~p", [ChallengerURI, Reason]),
            ok
    end,
    {noreply, State};
handle_cast({send_report, ReportType, Report, OnionKeyHash}, #state{connection = Connection, self_sig_fun = SelfSigFun} = State) ->
    lager:info("send_report ~p with onionkeyhash ~p: ~p", [ReportType, OnionKeyHash, Report]),
    ok = send_report(ReportType, Report, OnionKeyHash, SelfSigFun, Connection),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect_grpc, State) ->
    State0 = connect(State),
    {noreply, State0};
handle_info(connect_poc_stream, State) ->
    State0 = connect_poc_stream(State),
    {noreply, State0};

handle_info({'DOWN', Ref, process, _, Reason}, State = #state{conn_monitor_ref = Ref, connection = Connection}) ->
    lager:warning("GRPC connection to validator is down, reconnecting.  Reason: ~p", [Reason]),
    _ = grpc_client_custom:stop_connection(Connection),
    State0 = connect(State),
    {noreply, State0};
handle_info({'DOWN', Ref, process, _, Reason}, State = #state{stream_monitor_ref = Ref}) ->
    %% the poc stream is meant to be long lived, we always want it up as long as we have a grpc connection
    %% so if it goes down start it back up again
    lager:warning("GRPC stream to validator is down, reconnecting.  Reason: ~p", [Reason]),
    State0 = connect_poc_stream(State),
    {noreply, State0};

handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
connect(#state{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = State) ->
    try
        {ok, DefaultValidators} = application:get_env(miner, default_validators),
        %% pick a random validator as our streaming grpc server
        %% TODO: agree on approach to default validators, set in config, pull from peerbook or other
        {P2PAddr, PublicIP, GRPCPort} = lists:nth(rand:uniform(length(DefaultValidators)), DefaultValidators),
        lager:info("connecting to validator, p2paddr: ~p, ip: ~p, port: ~p", [P2PAddr, PublicIP, GRPCPort]),
        case miner_poc_grpc_client_handler:connect(P2PAddr, PublicIP, GRPCPort) of
            {error, _} ->
                erlang:send_after(1000, self(), connect_grpc),
                State;
            {ok, Connection} ->
                lager:info("successfully connected to validator via connection ~p", [Connection]),
                #{http_connection := ConnectionPid} = Connection,
                M = erlang:monitor(process, ConnectionPid),
                erlang:send_after(1000, self(), connect_poc_stream),
                State#state{connection = Connection, connection_pid = ConnectionPid, conn_monitor_ref = M, validator_p2p_addr = P2PAddr, validator_public_ip = PublicIP, validator_grpc_port = GRPCPort}
        end
    catch X:Y ->
        lager:info("failed to connect to validator, will try again in a bit. Reason: ~p, Details: ~p", [X, Y]),
        erlang:send_after(1000, self(), connect_grpc),
        State
    end.

connect_poc_stream(#state{connection = Connection, self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = State) ->
    try
        lager:info("establishing POC stream on connection ~p", [Connection]),
        case miner_poc_grpc_client_handler:poc_stream(Connection, SelfPubKeyBin, SelfSigFun) of
            {error, _} ->
                erlang:send_after(3000, self(), connect_poc_stream),
                State;
            {ok, Stream} ->
                lager:info("successfully connected stream ~p on connection ~p", [Stream, Connection]),
                M = erlang:monitor(process, Stream),
                State#state{stream_monitor_ref = M, stream_pid = Stream}
        end
    catch _Class:_Error ->
        lager:info("failed to establish poc stream on connection ~p, will try again in a bit. Reason: ~p, Details: ~p", [Connection, _Class, _Error]),
        erlang:send_after(3000, self(), connect_poc_stream),
        State
    end.

handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{target = true, onion = Onion} = _ChallengeResp, _ResponseHeight, _ResponseSig) ->
    ok = miner_onion_server_light:decrypt_p2p(Onion);
handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{target = false} = _ChallengeResp, _ResponseHeight, _ResponseSig) ->
    ok.

send_report(receipt = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedReceipt = gateway_client_pb:encode_msg(Report, blockchain_poc_receipt_v1_pb),
    SignedReceipt = Report#blockchain_poc_receipt_v1_pb{signature = SigFun(EncodedReceipt)},
    Req = #gateway_poc_report_req_v1_pb{onion_key_hash = OnionKeyHash,  msg = {ReportType, SignedReceipt}},
    %%TODO: add a retry mechanism ??
    _ = send_grpc_unary_req(Connection, Req, 'send_report'),
    ok;
send_report(witness = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedWitness = gateway_client_pb:encode_msg(Report, blockchain_poc_witness_v1_pb),
    SignedWitness = Report#blockchain_poc_witness_v1_pb{signature = SigFun(EncodedWitness)},
    Req = #gateway_poc_report_req_v1_pb{onion_key_hash = OnionKeyHash,  msg = {ReportType, SignedWitness}},
    _ = send_grpc_unary_req(Connection, Req, 'send_report'),
    ok.
%%
%%send_report(Type, Report, EncodedReport, OnionKeyHash, SigFun, Connection)->
%%    Report1 = Report#{signature => SigFun(EncodedReport)},
%%    Req = #{onion_key_hash => OnionKeyHash,  msg => {Type, Report1}},
%%    %%TODO: add a retry mechanism ??
%%    _ = send_grpc_unary_req(Connection, Req, 'send_report'),
%%    ok.


send_grpc_unary_req(undefined, _Req, _RPC) ->
    {grpc_error, no_connection};
send_grpc_unary_req(Connection, Req, RPC) ->
    try
        lager:info("send unary request: ~p", [Req]),
        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("send unary result: ~p", [Res]),
        process_unary_response(Res)
    catch
        X:Y:Z  ->
            lager:info("send unary failed: ~p, ~p, ~p", [X, Y, Z]),
            {grpc_error, req_failed}
    end.

send_grpc_unary_req(PeerIP, GRPCPort, Req, RPC)->
    try
        {ok, Connection} = grpc_client_custom:connect(tcp, PeerIP, GRPCPort),
        lager:info("New Connection, send unary request: ~p", [Req]),
        Res = grpc_client_custom:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_client_pb,
            [{callback_mod, miner_poc_grpc_client_handler}]
        ),
        lager:info("New Connection, send unary result: ~p", [Res]),
            %% we dont need the connection to hang around, so close it out
        _ = grpc_client_custom:stop_connection(Connection),
        process_unary_response(Res)
    catch
        X:Y:Z  ->
            lager:info("send unary failed: ~p, ~p, ~p", [X, Y, Z]),
            {grpc_error, req_failed}
    end.

build_check_target_req(ChallengerPubKeyBin, OnionKeyHash, BlockHash, ChallengeHeight, ChallengerSig, SelfPubKeyBin, SelfSigFun) ->
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
    ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_poc_check_challenge_target_req_v1_pb),
    Req#gateway_poc_check_challenge_target_req_v1_pb{challengee_sig = SelfSigFun(ReqEncoded)}.

build_region_params_req(Address, SigFun) ->
    Req = #gateway_poc_region_params_req_v1_pb{
        address = Address
    },
    ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_poc_region_params_req_v1_pb),
    Req#gateway_poc_region_params_req_v1_pb{signature = SigFun(ReqEncoded)}.



process_unary_response({error, #{http_status := 200, result := #{}, status_message := ErrorReason}}) ->
    {grpc_error, ErrorReason};
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {error_resp, #gateway_error_resp_pb{error = ErrorReason}}, height = Height, signature = Sig}}}) ->
    {error, ErrorReason, #{height => Height, signature => Sig}};
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {success_resp, _Payload}, height = Height, signature = Sig}}}) ->
    {ok, #{height => Height, signature => Sig}};
process_unary_response({ok, #{http_status := 200, result := #gateway_resp_v1_pb{msg = {_RespType, Payload}, height = Height, signature = Sig}}}) ->
    {ok, Payload, #{height => Height, signature => Sig}}.
