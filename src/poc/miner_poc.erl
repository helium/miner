%%%-------------------------------------------------------------------
%% @doc
%% == Miner PoC ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_poc).

-export([
    dial_framed_stream/3,
    add_stream_handler/1
]).

-define(POC_VERSION, "miner_poc/1.0.0").

%%--------------------------------------------------------------------
%% @doc
%% Dial PoC stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(ets:tab(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(SwarmTID, Address, Args) ->
    libp2p_swarm:dial_framed_stream(
        SwarmTID,
        Address,
        ?POC_VERSION,
        get_handler(),
        Args
    ).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(pid() | ets:tab()) -> ok.
add_stream_handler(SwarmTID) ->
    libp2p_swarm:add_stream_handler(
        SwarmTID,
        ?POC_VERSION,
        {libp2p_framed_stream, server, [get_handler(), self(), SwarmTID]}
    ).

-spec get_handler() -> miner_poc_report_handler | miner_poc_handler.
get_handler()->
    case application:get_env(miner, poc_transport, p2p) of
        grpc -> miner_poc_report_handler;
        _ -> miner_poc_handler
    end.