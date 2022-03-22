%%
%% grpc client handler for poc streamed msgs - WIP
%%
-module(miner_poc_grpc_client_handler).

-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").

%% ------------------------------------------------------------------
%% Stream Exports
%% ------------------------------------------------------------------
-export([
    init/0,
    handle_msg/2,
    handle_info/2
]).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-ifdef(TEST).
-export([
    connect/1
]).
-endif.

-export([
    connect/3,
    poc_stream/3,
    config_update_stream/1,
    region_params_update_stream/3,
    check_if_target/6
]).

init()->
    [].

-ifdef(TEST).
connect(PeerP2P) ->
    {ok, _PubKey, _SigFun, _} = blockchain_swarm:keys(),
    %% get the test specific grpc port for the peer
    %% ( which is going to be the libp2p port + 1000 )
    %% see miner_ct_utils for more info
    {ok, PeerGrpcPort} = p2p_port_to_grpc_port(PeerP2P),
    connect(PeerP2P, "127.0.0.1", PeerGrpcPort).
-endif.

-spec connect(libp2p_crypto:peer_id(), string(), non_neg_integer()) -> {ok, grpc_client_custom:connection()} | {error, any()}.
connect(PeerP2P, PeerIP, GRPCPort) ->
    try
        lager:debug("connecting over grpc to peer ~p via IP ~p and port ~p", [PeerP2P, PeerIP, GRPCPort]),
        {ok, Connection} = grpc_client_custom:connect(tcp, PeerIP, GRPCPort),
        {ok, Connection}
     catch _Error:_Reason:_Stack ->
        lager:warning("*** failed to connect over grpc to peer ~p.  Reason ~p Stack ~p", [PeerP2P, _Reason, _Stack]),
        {error, failed_to_connect_to_grpc_peer}
     end.

-spec poc_stream(grpc_client_custom:connection(), libp2p_crypto:pubkey_bin(), function()) -> {ok, pid()} | {error, any()}.
poc_stream(Connection, PubKeyBin, SigFun)->
    try
        {ok, Stream} = grpc_client_stream_custom:new(
            Connection,
            'helium.gateway',
            stream_poc,
            gateway_miner_client_pb,
            [{type, stream}],
            ?MODULE),
        lager:debug("*** new poc stream established with pid ~p", [Stream]),
        %% subscribe to poc updates
        Req = #gateway_poc_req_v1_pb{address = PubKeyBin, signature = <<>>},
        ReqEncoded = gateway_miner_client_pb:encode_msg(Req, gateway_poc_req_v1_pb),
        ReqSigned = Req#gateway_poc_req_v1_pb{signature = SigFun(ReqEncoded)},
        ok = grpc_client_custom:send(Stream, ReqSigned),
        {ok, Stream}
     catch _Error:_Reason:_Stack ->
        lager:warning("*** failed to connect to poc stream on connection ~p.  Reason ~p Stack ~p", [Connection, _Reason, _Stack]),
        {error, stream_failed}
     end.

-spec config_update_stream(grpc_client_custom:connection()) -> {ok, pid()} | {error, any()}.
config_update_stream(Connection)->
    try
        {ok, Stream} = grpc_client_stream_custom:new(
            Connection,
            'helium.gateway',
            config_update,
            gateway_miner_client_pb,
            [{type, stream}],
            ?MODULE),
        %% subscribe to config updates
        Req = #gateway_config_update_req_v1_pb{},
        ok = grpc_client_custom:send(Stream, Req),
        {ok, Stream}
     catch _Error:_Reason:_Stack ->
        lager:warning("*** failed to connect to config_update stream on connection ~p.  Reason ~p Stack ~p", [Connection, _Reason, _Stack]),
        {error, stream_failed}
     end.

-spec region_params_update_stream(grpc_client_custom:connection(), libp2p_crypto:pubkey_bin(), function()) -> {ok, pid()} | {error, any()}.
region_params_update_stream(Connection, PubKeyBin, SigFun)->
    try
        {ok, Stream} = grpc_client_stream_custom:new(
            Connection,
            'helium.gateway',
            region_params_update,
            gateway_miner_client_pb,
            [{type, stream}],
            ?MODULE),
        %% subscribe to region params updates
        Req = #gateway_region_params_update_req_v1_pb{address = PubKeyBin, signature = <<>>},
        ReqEncoded = gateway_miner_client_pb:encode_msg(Req, gateway_region_params_update_req_v1_pb),
        ReqSigned = Req#gateway_region_params_update_req_v1_pb{signature = SigFun(ReqEncoded)},
        ok = grpc_client_custom:send(Stream, ReqSigned),
        {ok, Stream}
    catch _Error:_Reason:_Stack ->
        lager:warning("*** failed to connect to region_params_update stream on connection ~p.  Reason ~p Stack ~p", [Connection, _Reason, _Stack]),
        {error, stream_failed}
    end.

-spec check_if_target(string(), libp2p_crypto:pubkey_bin(), binary(), binary(), pos_integer(),
                    function()) -> ok.
check_if_target(URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig) ->
    F = fun() ->
            TargetRes = miner_poc_grpc_client_statem:send_check_target_req(URI, PubKeyBin, OnionKeyHash, BlockHash,
                            NotificationHeight, ChallengerSig),
            lager:info("check target result for key ~p: ~p",[OnionKeyHash, TargetRes]),
            case TargetRes of
                {ok, Result, _Details} ->
                    handle_check_target_resp(Result);
                {error, <<"queued_poc">>, #{height := ValRespHeight } = _Details} ->
                    %% seems the POC key exists but the POC itself may not yet be initialised
                    %% this can happen if the challenging validator is behind our
                    %% notifying validator
                    %% if the challenger is behind the notifier, then add cache the check target req
                    %% it will then be retried periodically
                    N = NotificationHeight - ValRespHeight,
                    IsAlreadyCached = miner_poc_grpc_client_statem:is_queued_check_target_req(OnionKeyHash),
                    case (N > 0) andalso (not IsAlreadyCached) of
                        true ->
                            CurTSInSecs = erlang:monontonic_time(second),
                            _ = miner_poc_grpc_client_statem:queue_check_target_req(URI, PubKeyBin, OnionKeyHash, BlockHash,
                               NotificationHeight, ChallengerSig, CurTSInSecs),
                            lager:info("queued check target request for onionkeyhash ~p with ts ~p", [OnionKeyHash, CurTSInSecs]),
                            ok;
                        false ->
                            %% eh shouldnt hit here but ok
                            ok
                    end;
                {error, _Reason, _Details} ->
                    ok;
                {error, _Reason} ->
                    ok
            end
        end,
    spawn(F).



%% TODO: handle headers
handle_msg({headers, _Headers}, StreamState) ->
    lager:debug("*** grpc client ignoring headers ~p", [_Headers]),
    StreamState;
handle_msg({data, #gateway_resp_v1_pb{msg = {poc_challenge_resp, ChallengeNotification}, height = NotificationHeight, signature = ChallengerSig}} = Msg, StreamState) ->
    lager:debug("grpc client received gateway_poc_challenge_notification_resp_v1 msg ~p", [Msg]),
    #gateway_poc_challenge_notification_resp_v1_pb{challenger = #routing_address_pb{uri = URI, pub_key = PubKeyBin}, block_hash = BlockHash, onion_key_hash = OnionKeyHash} = ChallengeNotification,
    _ = check_if_target(URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig),
    StreamState;
handle_msg({data, #gateway_resp_v1_pb{msg = {config_update_streamed_resp, Payload}, height = _NotificationHeight, signature = _ChallengerSig}} = _Msg, StreamState) ->
    lager:debug("grpc client received config_update_streamed_resp msg ~p", [_Msg]),
    #gateway_config_update_streamed_resp_v1_pb{keys = UpdatedKeys} = Payload,
    _ = miner_poc_grpc_client_statem:update_config(UpdatedKeys),
    StreamState;
handle_msg({data, #gateway_resp_v1_pb{msg = {region_params_streamed_resp, Payload}, height = _NotificationHeight, signature = _ChallengerSig}} = _Msg, StreamState) ->
    lager:debug("grpc client received region_params_streamed_resp msg ~p", [_Msg]),
    #gateway_region_params_streamed_resp_v1_pb{region = Region, params =Params} = Payload,
    #blockchain_region_params_v1_pb{region_params = RegionParams} = Params,
    miner_lora_light:region_params_update(Region, RegionParams),
    miner_onion_server_light:region_params_update(Region, RegionParams),
    StreamState;
handle_msg({data, _Msg}, StreamState) ->
    lager:warning("grpc client received unexpected msg ~p",[_Msg]),
    StreamState.

handle_info({retry_check_target, URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig, Attempt}, StreamState)  when Attempt =< 3 ->
    lager:debug("retry_check_target with attempt ~p for onionkeyhash : ~p", [Attempt, OnionKeyHash]),
    _ = check_if_target(URI, PubKeyBin, OnionKeyHash, BlockHash, NotificationHeight, ChallengerSig),
    StreamState;
handle_info(_Msg, StreamState) ->
    lager:warning("grpc client unhandled msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{})-> ok.
handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{target = true, onion = Onion} = _ChallengeResp) ->
    ok = miner_onion_server_light:decrypt_p2p(Onion);
handle_check_target_resp(#gateway_poc_check_challenge_target_resp_v1_pb{target = false} = _ChallengeResp) ->
    ok.

-ifdef(TEST).
p2p_port_to_grpc_port(PeerAddr)->
    SwarmTID = blockchain_swarm:tid(),
    Peerbook = libp2p_swarm:peerbook(SwarmTID),
    {ok, _ConnAddr, {Transport, _TransportPid}} = libp2p_transport:for_addr(SwarmTID, PeerAddr),
    {ok, PeerPubKeyBin} = Transport:p2p_addr(PeerAddr),
    {ok, PeerInfo} = libp2p_peerbook:get(Peerbook, PeerPubKeyBin),
    ListenAddrs = libp2p_peer:listen_addrs(PeerInfo),
    [H | _ ] = libp2p_transport:sort_addrs(SwarmTID, ListenAddrs),
    [_, _, _IP,_, Port] = _Full = re:split(H, "/"),
    lager:info("*** peer p2p port ~p", [Port]),
    {ok, list_to_integer(binary_to_list(Port)) + 1000}.
-endif.
