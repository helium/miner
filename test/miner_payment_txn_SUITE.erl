-module(miner_payment_txn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
         init_per_suite/1
         ,end_per_suite/1
         ,init_per_testcase/2
         ,end_per_testcase/2
         ,all/0
        ]).

-export([
         single_payment_test/1
        ]).

%% common test callbacks

all() -> [
          single_payment_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    DKGResults = miner_ct_utils:pmap(fun(Miner) ->
                                             ct_rpc:call(Miner, miner, initial_dkg, [Addresses])
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
    GenesisBlock = blockchain:genesis_block(Chain),

    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    ok = miner_ct_utils:wait_until(fun() ->
                            lists:all(fun(M) ->
                                              1 == ct_rpc:call(M, blockchain_worker, height, [])
                                      end, Miners)
                    end),

    Config.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

single_payment_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    ct:pal("Payer: ~p, Payee :~p", [Payer, Payee]),
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, address, []),
    ct:pal("PayerAddr: ~p", [PayerAddr]),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, address, []),
    ct:pal("PayeeAddr: ~p", [PayeeAddr]),

    %% check initial balances
    %% FIXME: really need to be setting the balances elsewhere
    5000 = get_balance(Payer, PayerAddr),
    5000 = get_balance(Payee, PayerAddr),

    Ledger = ct_rpc:call(Payer, blockchain_worker, ledger, []),

    Fee = blockchain_ledger:transaction_fee(Ledger),

    %% send some helium tokens from payer to payee
    ok = ct_rpc:call(Payer, blockchain_worker, spend, [PayeeAddr, 1000, Fee]),

    %% XXX: presumably the transaction wouldn't have made it to the blockchain yet
    %% get the current height here
    CurrentHeight = ct_rpc:call(Payer, blockchain_worker, height, []),
    ct:pal("Payer: ~p, CurrentHeight: ~p", [Payer, CurrentHeight]),

    %% XXX: wait till the blockchain grows by 2 blocks
    %% assuming that the transaction makes it within 2 blocks
    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     Height = ct_rpc:call(Miner, blockchain_worker, height, []),
                                                                     ct:pal("Miner: ~p, Height: ~p", [Miner, Height]),
                                                                     Height >= CurrentHeight + 2
                                                             end, Miners)
                                   end, 60, timer:seconds(5)),

    PayerBalance = get_balance(Payer, PayerAddr),
    PayeeBalance = get_balance(Payee, PayeeAddr),

    4000 = PayerBalance + Fee,
    6000 = PayeeBalance,

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.


get_balance(Miner, Addr) ->
    Ledger = ct_rpc:call(Miner, blockchain_worker, ledger, []),
    Entries = ct_rpc:call(Miner, blockchain_ledger, entries, [Ledger]),
    Entry = ct_rpc:call(Miner, blockchain_ledger, find_entry, [Addr, Entries]),
    ct_rpc:call(Miner, blockchain_ledger, balance, [Entry]).
