%%%-------------------------------------------------------------------
%%% @author andrewmckenzie
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 28. Jul 2021 16:34
%%%-------------------------------------------------------------------
-module(miner_poc_grpc_utils).
-author("andrewmckenzie").

%% API
-export([
    p2p_port_to_grpc_port/1
]).

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

