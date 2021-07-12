%%%-------------------------------------------------------------------
%% @doc
%% == Miner Utility Functions ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_util).

-export([
         list_count/1,
         list_count_and_sort/1,
         index_of/2,
         h3_index/3,
         median/1,
         mark/2,
         metadata_fun/0,
         random_peer_predicate/1,
         has_valid_local_capability/2,
         hbbft_perf/0
        ]).

%% get the firmware release data from a hotspot
-define(LSB_FILE, "/etc/lsb_release").
-define(RELEASE_CMD, "cat " ++ ?LSB_FILE ++ " | grep RELEASE | cut -d'=' -f2").

-include_lib("blockchain/include/blockchain_vars.hrl").

%%-----------------------------------------------------------------------------
%% @doc Count the number of occurrences of each element in the list.
%% @end
%%-----------------------------------------------------------------------------
-spec list_count([A]) -> #{A => pos_integer()}.
list_count(Xs) ->
    lists:foldl(
        fun(X, Counts) -> maps:update_with(X, fun(C) -> C + 1 end, 1, Counts) end,
        #{},
        Xs
    ).

%%-----------------------------------------------------------------------------
%% @doc `list_count` then sort from largest-first (head) to smallest-last.
%% @end
%%-----------------------------------------------------------------------------
-spec list_count_and_sort([A]) -> [{A, pos_integer()}].
list_count_and_sort(Xs) ->
    lists:sort(fun({_, C1}, {_, C2}) -> C1 > C2 end, maps:to_list(list_count(Xs))).

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

-spec median([I]) -> I when I :: non_neg_integer().
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

-spec mark(atom(), atom()) -> ok.
mark(Module, MarkCurr) ->
    ActiveModules = application:get_env(miner, mark_mods, []),
    case lists:member(Module, ActiveModules) of
        true ->
            case get({Module, mark}) of
                undefined ->
                    lager:info("starting ~p mark at ~p", [Module, MarkCurr]),
                    put({Module, mark}, {MarkCurr, erlang:monotonic_time(millisecond)});
                {MarkCurr, _} -> % Ignore duplicate calls
                    ok;
                {MarkPrev, Start} ->
                    End = erlang:monotonic_time(millisecond),
                    put({Module, mark}, {MarkCurr, End}),
                    lager:info("~p interval ~p to ~p was ~pms",
                               [Module, MarkPrev, MarkCurr, End - Start])
            end;
        _ -> ok
    end.

metadata_fun() ->
    try
        Map = blockchain_worker:signed_metadata_fun(),
        case application:get_env(miner, mode, gateway) of
            validator ->
                Vsn = element(2, hd(release_handler:which_releases(permanent))),
                Map#{<<"release_version">> => list_to_binary(Vsn)};
            gateway ->
                FWRelease = case filelib:is_regular(?LSB_FILE) of
                                true ->
                                    iolist_to_binary(string:trim(os:cmd(?RELEASE_CMD)));
                                false ->
                                    <<"unknown">>
                            end,
                Map#{<<"release_info">> => FWRelease};
            _ ->
                Map
        end
    catch _:_ ->
              #{}
    end.

random_peer_predicate(Peer) ->
    not libp2p_peer:is_stale(Peer, timer:minutes(360)) andalso
        maps:get(<<"release_version">>, libp2p_peer:signed_metadata(Peer), undefined) /= undefined.

-spec has_valid_local_capability(Capability :: non_neg_integer(),
                                 Ledger :: blockchain_ledger_v1:ledger())->
    ok |
    {error, gateway_not_found} |
    {error, {invalid_capability, blockchain_ledger_gateway_v2:mode()}}.
has_valid_local_capability(Capability, Ledger) ->
    SelfAddr = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:find_gateway_info(SelfAddr, Ledger) of
        {error, _Reason} ->
            {error, gateway_not_found};
        {ok, GWAddrInfo} ->
            case blockchain_ledger_gateway_v2:is_valid_capability(GWAddrInfo, Capability, Ledger) of
                false ->
                    {error, {invalid_capability, blockchain_ledger_gateway_v2:mode(GWAddrInfo)}};
                true ->
                    ok
            end
    end.

hbbft_perf() ->
    %% calculate the current election start height
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    InitMap = maps:from_list([ {Addr, {0, 0}} || Addr <- ConsensusAddrs]),
    #{start_height := Start0, curr_height := End} = blockchain_election:election_info(Ledger),
    {Start, GroupWithPenalties} =
        case blockchain:config(?election_version, Ledger) of
            {ok, N} when N >= 5 ->
                Penalties = blockchain_election:validator_penalties(ConsensusAddrs, Ledger),
                Start1 = case End > (Start0 + 2) of
                             true -> Start0 + 2;
                             false -> End + 1
                         end,
                Penalties1 =
                    maps:map(
                      fun(Addr, Pen) ->
                              {ok, V} = blockchain_ledger_v1:get_validator(Addr, Ledger),
                              Pens = blockchain_ledger_validator_v1:calculate_penalties(V, Ledger),
                              {Pen + lists:sum(maps:values(Pens)), maps:get(tenure, Pens, 0.0)}
                      end, Penalties),
                {Start1, maps:to_list(Penalties1)};
            _ ->
                {Start0 + 1,
                 [{A, {S, 0.0}}
                  || {S, _L, A} <- blockchain_election:adjust_old_group(
                                     [{0, 0, A} || A <- ConsensusAddrs], Ledger)]}
        end,
    Blocks = [begin {ok, Block} = blockchain:get_block(Ht, Chain), Block end
                    || Ht <- lists:seq(Start, End)],
    {BBATotals, SeenTotals, TotalCount} =
        lists:foldl(
          fun(Blk, {BBAAcc, SeenAcc, Count}) ->
                  H = blockchain_block:height(Blk),
                  BBAs = blockchain_utils:bitvector_to_map(
                           length(ConsensusAddrs),
                           blockchain_block_v1:bba_completion(Blk)),
                  SeenVotes = blockchain_block_v1:seen_votes(Blk),
                  Seen = lists:foldl(
                           fun({_Idx, Votes0}, Acc) ->
                                   Votes = blockchain_utils:bitvector_to_map(
                                             length(ConsensusAddrs), Votes0),
                                   merge_map(ConsensusAddrs, Votes, H, Acc)
                           end,SeenAcc, SeenVotes),
                  {merge_map(ConsensusAddrs, BBAs, H, BBAAcc), Seen, Count + length(SeenVotes)}
          end, {InitMap, InitMap, 0}, Blocks),
    {ConsensusAddrs, BBATotals, SeenTotals, TotalCount, GroupWithPenalties, Start0, Start, End}.

merge_map(Addrs, Votes, Height, Acc) ->
    maps:fold(fun(K, true, A) ->
                       maps:update_with(lists:nth(K, Addrs), fun({_, V}) -> {Height, V+1} end, {Height, 1}, A);
                 (_, false, A) ->
                      A
              end, Acc, Votes).
