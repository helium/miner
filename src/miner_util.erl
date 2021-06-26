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
         has_valid_local_capability/2,
         mk_rescue_block/3
        ]).

-include_lib("blockchain/include/blockchain_vars.hrl").

%% get the firmware release data from a hotspot
-define(LSB_FILE, "/etc/lsb_release").
-define(RELEASE_CMD, "cat " ++ ?LSB_FILE ++ " | grep RELEASE | cut -d'=' -f2").

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

-spec mk_rescue_block(Vars :: #{atom() => term()},
                      Addrs :: [libp2p_crypto:pubkey_bin()],
                      KeyStr :: string()) ->
          blockchain_block:block().
mk_rescue_block(Vars, Addrs, KeyStr) ->
    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    Height = blockchain_block:height(HeadBlock),
    NewHeight = Height + 1,
    lager:info("new height is ~p", [NewHeight]),
    Hash = blockchain_block:hash_block(HeadBlock),
    NewRound = blockchain_block:hbbft_round(HeadBlock) + 1,

    #{secret := Priv} =
        libp2p_crypto:keys_from_bin(
          base58:base58_to_binary(KeyStr)),

    Ledger = blockchain:ledger(Chain),
    {ok, Nonce} = blockchain_ledger_v1:vars_nonce(Ledger),

    Txn = blockchain_txn_vars_v1:new(Vars, Nonce + 1),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    VarsTxn = blockchain_txn_vars_v1:proof(Txn, Proof),

    {ElectionEpoch, EpochStart} = blockchain_block_v1:election_info(HeadBlock),
    io:format("current election epoch: ~p new height: ~p~n", [ElectionEpoch, NewHeight]),

    GrpTxn = blockchain_txn_consensus_group_v1:new(Addrs, <<>>, NewHeight, 0),

    RewardsMod =
        case blockchain:config(?rewards_txn_version, Ledger) of
            {ok, 2} -> blockchain_txn_rewards_v2;
            _       -> blockchain_txn_rewards_v1
        end,
    Start = EpochStart + 1,
    End = Height,
    {ok, Rewards} = RewardsMod:calculate_rewards(Start, End, Chain),
    lager:debug("RewardsMod: ~p, Rewards: ~p~n", [RewardsMod, Rewards]),
    RewardsTxn = RewardsMod:new(Start, End, Rewards),

    RescueBlock = blockchain_block_v1:rescue(
                    #{prev_hash => Hash,
                      height => NewHeight,
                      transactions => [VarsTxn, GrpTxn, RewardsTxn],
                      hbbft_round => NewRound,
                      time => erlang:system_time(seconds),
                      election_epoch => ElectionEpoch + 1,
                      epoch_start => NewHeight}),

    EncodedBlock = blockchain_block:serialize(
                     blockchain_block_v1:set_signatures(RescueBlock, [])),

    RescueSigFun = libp2p_crypto:mk_sig_fun(Priv),

    RescueSig = RescueSigFun(EncodedBlock),

    blockchain_block_v1:set_signatures(RescueBlock, [], RescueSig).
