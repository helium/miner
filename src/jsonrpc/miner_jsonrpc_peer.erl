-module(miner_jsonrpc_peer).
-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"peer_session">>, []) ->
    Swarm = blockchain_swarm:swarm(),
    format_peer_sessions(Swarm);
handle_rpc(<<"peer_listen">>, []) ->
    SwarmTID = blockchain_swarm:tid(),
    Addrs = libp2p_swarm:listen_addrs(SwarmTID),
    format_listen_addrs(SwarmTID, Addrs);
handle_rpc(<<"peer_addr">>, []) ->
    #{
        <<"peer_addr">> =>
            ?TO_VALUE(libp2p_crypto:pubkey_bin_to_p2p(blockchain_swarm:pubkey_bin()))
    };
handle_rpc(<<"peer_connect">>, #{<<"addr">> := Addr}) when is_list(Addr) ->
    TID = blockchain_swarm:tid(),
    [connect_peer(TID, A) || A <- Addr];
handle_rpc(<<"peer_connect">>, #{<<"addr">> := Addr}) ->
    TID = blockchain_swarm:tid(),
    connect_peer(TID, Addr);
handle_rpc(<<"peer_connect">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"peer_ping">>, #{<<"addr">> := Addr}) when is_list(Addr) ->
    TID = blockchain_swarm:tid(),
    [ping_peer(TID, A) || A <- Addr];
handle_rpc(<<"peer_ping">>, #{<<"addr">> := Addr}) ->
    TID = blockchain_swarm:tid(),
    ping_peer(TID, Addr);
handle_rpc(<<"peer_ping">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"peer_book">>, #{<<"addr">> := <<"self">>}) ->
    peer_book_response(self);
handle_rpc(<<"peer_book">>, #{<<"addr">> := <<"all">>}) ->
    peer_book_response(all);
handle_rpc(<<"peer_book">>, #{<<"addr">> := Addr}) ->
    peer_book_response(Addr);
handle_rpc(<<"peer_book">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"peer_gossip_peers">>, []) ->
    [ ?TO_VALUE(A) || A <- blockchain_swarm:gossip_peers() ];
handle_rpc(<<"peer_gossip_peers">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"peer_refresh">>, #{ <<"addr">> := Addr}) ->
    do_peer_refresh(Addr);
handle_rpc(<<"peer_refresh">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%%
%% Internal
%%
connect_peer(TID, Addr) when is_binary(Addr) ->
    connect_peer(TID, binary_to_list(Addr));
connect_peer(TID, Addr) when is_list(Addr) ->
    case libp2p_swarm:connect(TID, Addr) of
        {ok, _} ->
            #{<<"connected">> => true};
        {error, _} = Error ->
            #{
                <<"connected">> => false,
                <<"error">> => ?TO_VALUE(Error)
            }
    end.

ping_peer(TID, Addr) when is_binary(Addr) ->
    ping_peer(TID, binary_to_list(Addr));
ping_peer(TID, Addr) when is_list(Addr) ->
    case libp2p_swarm:connect(TID, Addr) of
        {ok, Session} ->
            case libp2p_session:ping(Session) of
                {ok, RTT} ->
                    AddrKey = ?TO_KEY(Addr),
                    #{AddrKey => RTT};
                {error, _} = Error ->
                    AddrKey = ?TO_KEY(Addr),
                    #{
                        AddrKey => -1,
                        <<"error">> => ?TO_VALUE(Error)
                    }
            end;
        {error, _} = Err ->
            #{<<"error">> => ?TO_VALUE(Err)}
    end.

peer_book_response(Target) ->
    TID = blockchain_swarm:tid(),
    Peerbook = libp2p_swarm:peerbook(TID),

    %% Always return a list here, even when there's just
    %% a single entry
    case Target of
        all ->
            [ format_peer(P) || P <- libp2p_peerbook:values(Peerbook) ];
        self ->
            {ok, Peer} = libp2p_peerbook:get(Peerbook, blockchain_swarm:pubkey_bin()),
            [ lists:foldl(fun(M, Acc) -> maps:merge(Acc, M) end,
                        format_peer(Peer),
                        [format_listen_addrs(TID, libp2p_peer:listen_addrs(Peer)),
                         format_peer_sessions(TID)]
                       ) ];
        Addrs when is_list(Addrs) ->
            [begin
                 {ok, P} = libp2p_peerbook:get(Peerbook, libp2p_crypto:p2p_to_pubkey_bin(binary_to_list(A))),
                 lists:foldl(fun(M, Acc) -> maps:merge(Acc, M) end,
                             format_peer(P),
                             [format_listen_addrs(TID, libp2p_peer:listen_addrs(P)),
                              format_peer_connections(P)])
             end || A <- Addrs ];
        Addr ->
            {ok, P} = libp2p_peerbook:get(Peerbook, libp2p_crypto:p2p_to_pubkey_bin(binary_to_list(Addr))),
            [ lists:foldl(fun(M, Acc) -> maps:merge(Acc, M) end,
                          format_peer(P),
                          [format_listen_addrs(TID, libp2p_peer:listen_addrs(P)),
                          format_peer_connections(P)]) ]
    end.

format_peer(Peer) ->
    ListenAddrs = libp2p_peer:listen_addrs(Peer),
    ConnectedTo = libp2p_peer:connected_peers(Peer),
    NatType = libp2p_peer:nat_type(Peer),
    Timestamp = libp2p_peer:timestamp(Peer),
    Bin = libp2p_peer:pubkey_bin(Peer),
    M = #{
        <<"address">> => libp2p_crypto:pubkey_bin_to_p2p(Bin),
        <<"name">> => ?BIN_TO_ANIMAL(Bin),
        <<"listen_addr_count">> => length(ListenAddrs),
        <<"connection_count">> => length(ConnectedTo),
        <<"nat">> => NatType,
        <<"last_updated">> => (erlang:system_time(millisecond) - Timestamp) / 1000
    },
    maps:map(fun(_K, V) -> ?TO_VALUE(V) end, M).

format_peer_connections(Peer) ->
    #{
        <<"connections">> => [
            ?TO_VALUE(libp2p_crypto:pubkey_bin_to_p2p(P))
         || P <- libp2p_peer:connected_peers(Peer)
        ]
    }.

format_listen_addrs(TID, Addrs) ->
    libp2p_transport:sort_addrs(TID, Addrs),
    #{<<"listen_addresses">> => [?TO_VALUE(A) || A <- Addrs]}.

format_peer_sessions(Swarm) ->
    SessionInfos = libp2p_swarm:sessions(Swarm),
    Rs = lists:filtermap(
        fun({A, S}) ->
            case multiaddr:protocols(A) of
                [{"p2p", B58}] ->
                    {true, {A, libp2p_session:addr_info(libp2p_swarm:tid(Swarm), S), B58}};
                _ ->
                    false
            end
        end,
        SessionInfos
    ),

    FormatEntry = fun({MA, {SockAddr, PeerAddr}, B58}) ->
        M = #{
            <<"local">> => SockAddr,
            <<"remote">> => PeerAddr,
            <<"p2p">> => MA,
            <<"name">> => ?B58_TO_ANIMAL(B58)
        },
        maps:map(fun(_K, V) -> ?TO_VALUE(V) end, M)
    end,
    #{ <<"sessions">> => [FormatEntry(E) || E <- Rs] }.

do_peer_refresh(Addr) when is_list(Addr) ->
    TID = blockchain_swarm:tid(),
    Peerbook = libp2p_swarm:peerbook(TID),
    [ #{ A => do_refresh(Peerbook, A) } ||
      A <- Addr ];
do_peer_refresh(Addr) ->
    do_peer_refresh([Addr]).

do_refresh(Peerbook, A) ->
    libp2p_peerbook:refresh(Peerbook, libp2p_crypto:p2p_to_pubkey_bin(A)).
