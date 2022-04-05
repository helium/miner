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
    region_params_update_stream/3
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
        grpc_client_custom:connect(tcp, PeerIP, GRPCPort)
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

%% TODO: handle headers
handle_msg({headers, _Headers}, StreamState) ->
    lager:debug("*** grpc client ignoring headers ~p", [_Headers]),
    StreamState;
%% handle streamed msgs received by this client
handle_msg({data, Msg}, StreamState) ->
    lager:debug("grpc client handler received msg ~p", [Msg]),
    _ = miner_poc_grpc_client_statem:handle_streamed_msg(Msg),
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
