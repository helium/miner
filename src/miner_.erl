%%% Mockable innards of miner module.
-module(miner_).

-export([
    schedule_next_block_timeout/1
]).

schedule_next_block_timeout(NextBlockTime) ->
    erlang:send_after(NextBlockTime * 1000, self(), block_timeout).
