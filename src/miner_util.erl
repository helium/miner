%%%-------------------------------------------------------------------
%% @doc
%% == Miner Utility Functions ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_util).

-export([
         index_of/2,
         h3_index/3,
         median/1,
         mark/2
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

h3_index(Lat, Lon, Accuracy) ->
    %% for each resolution, see how close our accuracy is
    R = lists:foldl(fun(Resolution, Acc) ->
                              EdgeLength = h3:edge_length_meters(Resolution),
                              [{abs(EdgeLength - Accuracy/1000), Resolution}|Acc]
                      end, [], lists:seq(0, 15)),
    {_, Resolution} = hd(lists:keysort(1, R)),
    lager:info("Resolution ~p is best for accuracy of ~p meters", [Resolution, Accuracy/1000]),
    {h3:from_geo({Lat, Lon}, Resolution), Resolution}.

median([]) -> 0;
median(List) ->
    Length = length(List),
    Sorted = lists:sort(List),
    case Length rem 2 == 0 of
        false ->
            %% not an even length, there's a clear midpoint
            lists:nth((Length div 2) + 1, Sorted);
        true ->
            %% average the 2 middle values
            (lists:nth(Length div 2, Sorted) + lists:nth((Length div 2) + 1, Sorted)) div 2
    end.

mark(Module, Mark) ->
    ActiveModules = application:get_env(miner, mark_mods, []),
    case lists:member(Module, ActiveModules) of
        true ->
            case get({Module, mark}) of
                undefined ->
                    lager:info("starting ~p mark at ~p", [Module, Mark]),
                    put({Module, mark}, {Mark, erlang:monotonic_time(millisecond)});
                {Prev, Start} ->
                    End = erlang:monotonic_time(millisecond),
                    put({Module, mark}, {Mark, End}),
                    lager:info("~p interval ~p to ~p was ~pms",
                               [Module, Prev, Mark, End - Start])
            end;
        _ -> ok
    end.
