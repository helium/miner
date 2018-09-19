%%%-------------------------------------------------------------------
%% @doc
%% == Miner Utility Functions ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_util).

-export([
    index_of/2
]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec index_of(any(), [any()]) -> pos_integer().
index_of(Item, List) -> index_of(Item, List, 1).

index_of(_, [], _)  -> not_found;
index_of(Item, [Item|_], Index) -> Index;
index_of(Item, [_|Tl], Index) -> index_of(Item, Tl, Index+1).
