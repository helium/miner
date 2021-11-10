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
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    receipts(Height).

receipts(Height) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Block} = blockchain:get_block(Height, Chain),
    Reqs = filter_requests(Block),
    Recs = filter_receipts(Block),
    profile_receipts(Reqs, Recs, Height, Chain).

profile_receipts(Reqs, Recs, Height, Chain) ->
    {ok, LedgerAt0} = blockchain:ledger_at(Height - 1, Chain),
    LedgerAt = blockchain_ledger_v1:new_context(LedgerAt0),
    Chain1 = blockchain:ledger(LedgerAt, Chain),
    lists:foreach(fun(T) -> blockchain_txn:absorb(T, Chain1) end, Reqs),
    eprof:start_profiling([self()]),
    blockchain_txn:validate(Recs, Chain1),
    eprof:stop_profiling(),
    blockchain_ledger_v1:delete_context(LedgerAt),
    ok.

%% depending on how far back the last election was, this might not always be runnable
rewards() ->
    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {_Epoch, ElectionHeight} = blockchain_block_v1:election_info(HeadBlock),
    {ok, Block} = blockchain:get_block(ElectionHeight, Chain),
    Rewards = filter_rewards(Block),
    profile_txns(Rewards, ElectionHeight, Chain, true).
