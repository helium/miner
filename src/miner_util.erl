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
         mark/2,
         metadata_fun/0
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

metadata_fun() ->
    try
        Map = blockchain_worker:signed_metadata_fun(),
        case miner_lora:position() of
            %% GPS location that's adequately close to the asserted
            %% location
            {ok, _} ->
                Map#{<<"gps_fix_quality">> => <<"good_fix">>};
            %% the assert location is too far from the fix
            {ok, bad_assert, _} ->
                Map#{<<"gps_fix_quality">> => <<"bad_assert">>};
            %% no gps fix
            {error, no_fix} ->
                Map#{<<"gps_fix_quality">> => <<"no_fix">>};
            %% no location asserted somehow
            {error, not_asserted} ->
                Map#{<<"gps_fix_quality">> => <<"not_asserted">>};
            %% got nonsense or a hopefully transient error, return nothing
            _ ->
                Map#{<<"gps_fix_quality">> => <<"no_fix">>}
        end
    catch C:E:S ->
            lager:info("fuuu ~p ~p ~p", [C, E, S]),
            #{}
    end.
