%%%-------------------------------------------------------------------
%% @doc miner_console
%% @end
%%%-------------------------------------------------------------------
-module(miner_console).

-export([command/1]).

-spec command([string()]) -> ok.
command(Cmd) ->
    clique:run(Cmd).
