-module(miner_bulk_txn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         bulk_payment_test/1
        ]).

-define(BALANCE, 100000000).

%% common test callbacks

all() -> [
          bulk_payment_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, ?BALANCE) || Addr <- Addresses],
    DKGResults = miner_ct_utils:pmap(fun(Miner) ->
                                             ct_rpc:call(Miner, miner, initial_dkg, [InitialPaymentTransactions, Addresses])
                                     end, Miners),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner, in_consensus, [])
                                         end, Miners),

    %% ensure that blockchain is undefined for non_consensus miners
    true = lists:all(fun(Res) ->
                             Res == undefined
                     end,
                     lists:foldl(fun(Miner, Acc) ->
                                         R = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                         [R | Acc]
                                 end, [], NonConsensusMiners)),

    %% get the genesis block from the first Consensus Miner
    ConsensusMiner = hd(lists:filtermap(fun(Miner) ->
                                                true == ct_rpc:call(Miner, miner, in_consensus, [])
                                        end, Miners)),
    Chain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Chain]),

    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    ok = miner_ct_utils:wait_until(fun() ->
                                           lists:all(fun(M) ->
                                                             C = ct_rpc:call(M, blockchain_worker, blockchain, []),
                                                             {ok, 1} == ct_rpc:call(M, blockchain, height, [C])
                                                     end, Miners)
                                   end),

    [{total_txns, 100}, {txn_frequency, 10}, {amount, 1000} | Config].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

bulk_payment_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    TotalTxns = proplists:get_value(total_txns, Config),
    TxnFrequency = proplists:get_value(txn_frequency, Config),
    Amount = proplists:get_value(amount, Config),

    [Payer, Payee | _Tail] = Miners,
    PayerPubkey = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeePubkey = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    ?BALANCE = get_balance(Payer, PayerPubkey),
    ?BALANCE = get_balance(Payee, PayerPubkey),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, _Pubkey, SigFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    %% Let's check whether 100 txns made 10 at a time work within reasonable bounds of time/height
    _AllTxns = lists:foldl(fun(NonceList, Acc0) ->
                               {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),
                               Txns = lists:reverse(lists:foldl(fun(Nonce, Acc) ->
                                                                         Txn = ct_rpc:call(Payer,
                                                                                           blockchain_txn_payment_v1,
                                                                                           new,
                                                                                           [PayerPubkey, PayeePubkey, Amount, Fee, Nonce]),
                                                                         SignedTxn = ct_rpc:call(Payer,
                                                                                                 blockchain_txn_payment_v1,
                                                                                                 sign,
                                                                                                 [Txn, SigFun]),
                                                                         ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),
                                                                         [SignedTxn | Acc]
                                                                 end, [], NonceList)),
                               [Txns | Acc0]
                       end, [], partition(lists:seq(1, TotalTxns), TxnFrequency)),

    %% Presumably the transaction wouldn't have made it to the blockchain yet
    %% get the current height here
    Chain2 = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, CurrentHeight} = ct_rpc:call(Payer, blockchain, height, [Chain2]),

    %% Wait till the blockchain grows by 5 blocks
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->
                                      C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                      {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C]),
                                      Height >= CurrentHeight + 5
                              end,
                              Miners
                             )
           end,
           60,
           timer:seconds(10)
          ),

    Chain3 = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, FinalHeight} = ct_rpc:call(Payer, blockchain, height, [Chain3]),

    ok = lists:foreach(fun(Height) ->
                               {ok, Block} = ct_rpc:call(Payer, blockchain, get_block, [Height, Chain3]),
                               Txns = ct_rpc:call(Payer, blockchain_block, transactions, [Block]),
                               ct:pal("Height: ~p, Txns: ~p", [Height, length(Txns)])
                       end, lists:seq(1, FinalHeight)),

    PayerBalance = get_balance(Payer, PayerPubkey),
    PayeeBalance = get_balance(Payee, PayeePubkey),

    ?BALANCE = PayerBalance + (TotalTxns * Amount),
    ?BALANCE = PayeeBalance - (TotalTxns * Amount),

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.

get_balance(Miner, Addr) ->
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Entry} = ct_rpc:call(Miner, blockchain_ledger_v1, find_entry, [Addr, Ledger]),
    ct_rpc:call(Miner, blockchain_ledger_entry_v1, balance, [Entry]).

partition([], _) -> [];
partition(L, N) ->
    try lists:split(N, L) of
        {H, T} -> [H | partition(T, N)]
    catch
        error:badarg -> [L]
    end.
