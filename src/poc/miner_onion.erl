%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion).

-export([
    dial_framed_stream/3,
    add_stream_handler/1
]).

-define(ONION_VERSION, "miner_onion/1.0.0").

%%--------------------------------------------------------------------
%% @doc
%% Dial Onion stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(pid(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(Swarm, Address, Args) ->
    libp2p_swarm:dial_framed_stream(
        Swarm,
        Address,
        ?ONION_VERSION,
        miner_onion_handler,
        Args
    ).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(pid()) -> ok.
add_stream_handler(Swarm) ->
    TID = libp2p_swarm:tid(Swarm),
    libp2p_swarm:add_stream_handler(
        TID,
        ?ONION_VERSION,
        {libp2p_framed_stream, server, [miner_onion_handler, self(), TID]}
    ).
