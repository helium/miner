-module(miner_blockchain_SUITE).

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
         consensus_test/1
         ,genesis_load_test/1
         ,growth_test/1
        ]).

%% common test callbacks

all() -> [
          consensus_test
          ,genesis_load_test
          ,growth_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    DKGResults = miner_ct_utils:pmap(fun(Miner) ->
                                             ct_rpc:call(Miner, miner, initial_dkg, [InitialPaymentTransactions, Addresses])
                                     end, Miners),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),
    Config.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

consensus_test(Config) ->
    NumConsensusMiners = proplists:get_value(num_consensus_members, Config),
    Miners = proplists:get_value(miners, Config),
    NumNonConsensusMiners = length(Miners) - NumConsensusMiners,
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),
    NumConsensusMiners = length(ConsensusMiners),
    NumNonConsensusMiners = length(Miners) - NumConsensusMiners,
    {comment, ConsensusMiners}.

genesis_load_test(Config) ->
    Miners = proplists:get_value(miners, Config),
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

    Blockchain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),

    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Blockchain]),

    GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                     ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                             end, NonConsensusMiners),
    {comment, GenesisLoadResults}.

growth_test(Config) ->
    Miners = proplists:get_value(miners, Config),

    %% check consensus miners
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner, in_consensus, [])
                                         end, Miners),

    %% get the first consensus miner
    FirstConsensusMiner = hd(ConsensusMiners),

    Blockchain = ct_rpc:call(FirstConsensusMiner, blockchain_worker, blockchain, []),

    %% get the genesis block from first consensus miner
    {ok, GenesisBlock} = ct_rpc:call(FirstConsensusMiner, blockchain, genesis_block, [Blockchain]),

    %% check genesis load results for non consensus miners
    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    %% wait till the chain reaches height 2 for all miners
    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     Height = ct_rpc:call(Miner, blockchain_worker, height, []),
                                                                     Height >= 3
                                                             end, Miners)
                                   end, 60, timer:seconds(10)),

    Heights = lists:foldl(fun(Miner, Acc) ->
                                  {ok, H} = ct_rpc:call(Miner, blockchain_worker, height, []),
                                  [{Miner, H} | Acc]
                          end, [], Miners),

    {comment, Heights}.
