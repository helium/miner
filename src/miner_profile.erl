-module(miner_profile).

-compile(export_all).


requests() ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    requests(Height).

requests(Height) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Block} = blockchain:get_block(Height, Chain),
    Reqs = filter_requests(Block),
    profile_txns(Reqs, Height, Chain).

filter_requests(Block) ->
    lists:filter(
      fun(T) ->
              blockchain_txn:type(T) == blockchain_txn_poc_request_v1
      end, blockchain_block:transactions(Block)).

filter_receipts(Block) ->
    lists:filter(
      fun(T) ->
              blockchain_txn:type(T) == blockchain_txn_poc_receipts_v1
      end, blockchain_block:transactions(Block)).

filter_rewards(Block) ->
    lists:filter(
      fun(T) ->
              Type = blockchain_txn:type(T),
              Type == blockchain_txn_rewards_v1 orelse
                  Type == blockchain_txn_rewards_v2
      end, blockchain_block:transactions(Block)).

profile_txns(Reqs, Height, Chain) ->
    profile_txns(Reqs, Height, Chain, false).

profile_txns(Reqs, Height, Chain, Precalc) ->
    {ok, LedgerAt0} = blockchain:ledger_at(Height - 1, Chain),
    LedgerAt = blockchain_ledger_v1:new_context(LedgerAt0),
    Chain1 = blockchain:ledger(LedgerAt, Chain),
    case Precalc of
        true ->
            blockchain_ledger_v1:vars(#{regulatory_regions => <<"region_as923_1,region_as923_2,region_as923_3,region_as923_4,region_au915,region_cn470,region_eu433,region_eu868,region_in865,region_kr920,region_ru864,region_us915">>},
                                    [], LedgerAt),
            blockchain_hex:precalc(false, LedgerAt);
        false ->
            ok
    end,
    eprof:start_profiling([self()]),
    blockchain_txn:validate(Reqs, Chain1),
    eprof:stop_profiling(),
    blockchain_ledger_v1:delete_context(LedgerAt),
    ok.

receipts() ->
    receipts(10).

receipts(Version) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    receipts(Version, Height).

receipts(Version, Height) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Block} = blockchain:get_block(Height, Chain),
    Reqs = filter_requests(Block),
    Recs = filter_receipts(Block),
    profile_receipts(Reqs, Recs, Version, Height, Chain).

profile_receipts(Reqs, Recs, Version, Height, Chain) ->
    {ok, LedgerAt0} = blockchain:ledger_at(Height - 1, Chain),
    LedgerAt = blockchain_ledger_v1:new_context(LedgerAt0),
    io:format("setting version to ~p~n", [Version]),
    %%ok = blockchain_ledger_v1:vars(#{poc_version => Version}, [], DLedgerAt1),
    persistent_term:put(poc_version_var, Version),
    Chain1 = blockchain:ledger(LedgerAt, Chain),
    lists:foreach(fun(T) -> blockchain_txn:absorb(T, Chain1) end, Reqs),
    Start = erlang:monotonic_time(millisecond),
    eprof:start_profiling([self()]),
    blockchain_txn:validate(Recs, Chain1),
    eprof:stop_profiling(),
    blockchain_ledger_v1:delete_context(LedgerAt),
    erlang:monotonic_time(millisecond) - Start.

%% depending on how far back the last election was, this might not always be runnable
rewards() ->
    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {_Epoch, ElectionHeight} = blockchain_block_v1:election_info(HeadBlock),
    {ok, Block} = blockchain:get_block(ElectionHeight, Chain),
    Rewards = filter_rewards(Block),
    profile_txns(Rewards, ElectionHeight, Chain, true).
