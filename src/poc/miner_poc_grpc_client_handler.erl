%%
%% grpc client handler for poc streamed msgs - WIP
%%
-module(miner_poc_grpc_client_handler).

%% ------------------------------------------------------------------
%% Stream Exports
%% ------------------------------------------------------------------
-export([
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
    connect/3
]).

-ifdef(TEST).
connect(PeerP2P) ->
    %% get the test specific grpc port for the peer
    %% ( which is going to be the libp2p port + 1000 )
    %% see miner_ct_utils for more info
    {ok, PeerGrpcPort} = p2p_port_to_grpc_port(PeerP2P),
    connect(PeerP2P, "127.0.0.1", PeerGrpcPort).
-endif.

connect(PeerP2P, PeerIP, GRPCPort) ->
    try
        lager:info("connecting over grpc to peer ~p via IP ~p and port ~p", [PeerP2P, PeerIP, GRPCPort]),
        {ok, Connection} = grpc_client:connect(tcp, PeerIP, GRPCPort),
        grpc_client_stream_custom:new(
            Connection,
            'helium.gateway',
            stream,
            gateway_client_pb,
            [],
            ?MODULE
        )
     catch _Error:_Reason:_Stack ->
        lager:warning("*** failed to connect over grpc to peer ~p.  Reason ~p Stack ~p", [PeerP2P, _Reason, _Stack]),
        {error, failed_to_connect_to_grpc_peer}
     end.


%% TODO: handle headers
handle_msg({headers, _Headers}, StreamState) ->
    lager:debug("*** grpc client ignoring headers ~p", [_Headers]),
    StreamState;
%% TODO: handle eof
handle_msg(eof, StreamState) ->
    lager:debug("*** grpc client received eof", []),
    StreamState;
handle_msg({data, #{msg := {poc_challenge_resp, ChallengeNotification}, height := NotificationHeight, signature := ChallengerSig}} = _Msg, StreamState) ->
    lager:debug("grpc client received poc_challenge_resp msg ~p", [_Msg]),
    ok = miner_poc_grpc_client:check_target(ChallengeNotification, NotificationHeight, ChallengerSig),
    StreamState;
handle_msg({data, _Msg}, StreamState) ->
    StreamState.

handle_info(_Msg, StreamState) ->
    lager:warning("grpc client unhandled msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
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