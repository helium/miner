%%%-------------------------------------------------------------------
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_grpc_client).

-behaviour(gen_server).

-include_lib("public_key/include/public_key.hrl").

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    connection/0,
    check_target/3,
    send_report/3
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
    monitor_ref,
    validator_p2p_addr,
    validator_public_ip,
    validator_grpc_port
}).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link([]) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

connection() ->
    gen_server:call(?MODULE, connection, infinity).

check_target(ChallengeNotification, NotificationHeight, ChallengerSig) ->
    gen_server:cast(?MODULE, {check_target, ChallengeNotification, NotificationHeight, ChallengerSig}).

send_report(ReportType, Report, OnionKeyHash)->
    gen_server:cast(?MODULE, {send_report, ReportType, Report, OnionKeyHash}).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(_Args) ->
    erlang:send_after(500, self(), connect_stream),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    {ok, _, SigFun, _} = blockchain_swarm:keys(),
    DefaultValidators = application:get_env(miner, default_validators),
    %% pick a random validator as our streaming grpc server
    {P2PAddr, PublicIP, GRPCPort} = lists:nth(rand:uniform(length(DefaultValidators)), DefaultValidators),
    {ok, #state{validator_p2p_addr = P2PAddr, validator_public_ip = PublicIP, validator_grpc_port = GRPCPort, self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SigFun}}.

handle_call(connection, _From, State = #state{connection = Connection}) ->
    {reply, {ok, Connection}, State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast({check_target, ChallengeNotification, NotificationHeight, ChallengerSig}, #state{self_pub_key_bin = SelfPubKeyBin, self_sig_fun = SelfSigFun} = State) ->
    %% get the challenger route details from the challenge msg we recevied
    #{challenger := #{uri := URI}} = ChallengeNotification,
    %% split the URI into its IP and port parts
    #{host := IP, port := Port, scheme := _Scheme} = uri_string:parse(URI),
    %% build the request
    Req = build_check_target_req(NotificationHeight, ChallengerSig, ChallengeNotification, SelfPubKeyBin, SelfSigFun),
    {ok, ChallengerConnection} = grpc_client:connect(tcp, IP, Port),
    %% TODO: verify headers
    {ok, #{
            headers := _Headers,
            result := #{
                msg := {poc_check_target_resp, ChallengeResp},
                height := ResponseHeight,
                signature := ResponseSig
            } = _Result
        }} = send_grpc_unary_req(ChallengerConnection, Req, 'check_challenge_target'),
    %% we dont need the connection to hang around, so close it out
    _ = grpc_client:stop_connection(ChallengerConnection),
    %% handle the result as to if we are the target or not
    ok = handle_check_target_resp(ChallengeResp, ResponseHeight, ResponseSig),
    {noreply, State};
handle_cast({send_report, ReportType, Report, OnionKeyHash}, #state{connection = Connection, self_sig_fun = SelfSigFun} = State) ->
    ok = send_report(ReportType, Report, OnionKeyHash, SelfSigFun, Connection),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect_stream, State) ->
    State0 = connect(State),
    {noreply, State0};
handle_info({'DOWN', Ref, process, _, Reason}, State = #state{monitor_ref = Ref}) ->
    lager:warning("GRPC connection to validator is down, reconnection.  Reason: ~p", [Reason]),
    State0 = connect(State),
    {noreply, State0};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
connect(#state{validator_p2p_addr = P2PAddr, validator_public_ip = PublicIP, validator_grpc_port = GRPCPort} = State) ->
    case miner_poc_grpc_client_handler:connect(P2PAddr, PublicIP, GRPCPort) of
        {error, _} ->
            erlang:send_after(500, self(), connect_stream),
            State;
        {ok, Connection} ->
            M = erlang:monitor(process, Connection),
            State#state{connection = Connection, monitor_ref = M}
    end.

handle_check_target_resp(#{target := true, onion := Onion} = _ChallengeResp, _ResponseHeight, _ResponseSig) ->
    ok = miner_onion_server:decrypt_p2p(Onion);
handle_check_target_resp(#{target := false} = _ChallengeResp, _ResponseHeight, _ResponseSig) ->
    ok.

send_report(receipt = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedReceipt = gateway_client_pb:encode_msg(Report, blockchain_poc_receipt_v1_pb),
    send_report(ReportType, Report, EncodedReceipt, OnionKeyHash, SigFun, Connection);
send_report(witness = ReportType, Report, OnionKeyHash, SigFun, Connection) ->
    EncodedWitness = gateway_client_pb:encode_msg(Report, blockchain_poc_witness_v1_pb),
    send_report(ReportType, Report, EncodedWitness, OnionKeyHash, SigFun, Connection).

send_report(Type, Report, EncodedReport, OnionKeyHash, SigFun, Connection)->
    Report1 = Report#{signature => SigFun(EncodedReport)},
    Req = #{onion_key_hash => OnionKeyHash,  msg => {Type, Report1}},
    %%TODO: add a retry mechanism ??
    %% TODO: verify headers
    {ok, #{
            headers := _Headers,
            result := #{
                msg := {success_resp, Resp},
                height := _ResponseHeight,
                signature := _ResponseSig
            } = _Result
        }} = send_grpc_unary_req(Connection, Req, 'send_report'),
    ok.

send_grpc_unary_req(Connection, Req, RPC)->
    grpc_client:unary(
            Connection,
            Req,
            'helium.gateway',
            RPC,
            gateway_client_pb,
            []
        ).

build_check_target_req(ChallengeHeight, ChallengerSig, ChallengeMsg, MyPubKeyBin, SelfSigFun) ->
    #{challenger := #{pub_key := ChallengerPubKeyBin}, block_hash := BlockHash, onion_key_hash := OnionKeyHash} = ChallengeMsg,
    Req = #{
        address => MyPubKeyBin,
        challenger => ChallengerPubKeyBin,
        block_hash => BlockHash,
        onion_key_hash => OnionKeyHash,
        height => ChallengeHeight,
        notifier => ChallengerPubKeyBin,
        notifier_sig => ChallengerSig,
        challengee_sig => <<>>
    },
    ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_poc_check_challenge_target_req_v1_pb),
    Req#{challengee_sig => SelfSigFun(ReqEncoded)}.