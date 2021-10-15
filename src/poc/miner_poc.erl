%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc).

-export([
    dial_framed_stream/4,
    add_stream_handler/2
]).

-define(POC_VERSION, "miner_poc/1.0.0").

%%--------------------------------------------------------------------
%% @doc
%% Dial PoC stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(ets:tab(), string(), atom(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(SwarmTID, Address, HandlerMod, Args) ->
    libp2p_swarm:dial_framed_stream(
        SwarmTID,
        Address,
        ?POC_VERSION,
        HandlerMod,
        Args
    ).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(pid() | ets:tab(), atom()) -> ok.
add_stream_handler(SwarmTID, HandlerMod) ->
    libp2p_swarm:add_stream_handler(
        SwarmTID,
        ?POC_VERSION,
        {libp2p_framed_stream, server, [HandlerMod, self(), SwarmTID]}
    ).

