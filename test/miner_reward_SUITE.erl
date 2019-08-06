-module(miner_reward_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         basic_test/1
        ]).

%% common test callbacks

all() -> [
          basic_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    InitialCoinbaseTxns = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, undefined, 0) || Addr <- Addresses],

    N = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = 5,
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => N,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [InitialVars ++ InitialCoinbaseTxns ++ AddGwTxns, Addresses,
                                        N, Curve])
                   end, Miners),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                         end, Miners),

    %% ensure that blockchain is undefined for non_consensus miners
    true = lists:all(fun(Res) ->
                             Res == undefined
                     end,
                     lists:foldl(fun(Miner, Acc) ->
                                         R = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                         [R | Acc]
                                 end, [], NonConsensusMiners)),

    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                                true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                        end, Miners),

    %% get the genesis block from the first Consensus Miner
    ConsensusMiner = hd(ConsensusMiners),
    Chain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Chain]),

    ct:pal("non consensus nodes ~p", [NonConsensusMiners]),

    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    ok = miner_ct_utils:wait_until(fun() ->
                                           lists:all(fun(M) ->
                                                             C = ct_rpc:call(M, blockchain_worker, blockchain, []),
                                                             {ok, 1} == ct_rpc:call(M, blockchain, height, [C])
                                                     end, Miners)
                                   end),

    [{consensus_miners, ConsensusMiners}, {non_consensus_miners, NonConsensusMiners} | Config].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    ConsensusMiners = proplists:get_value(consensus_miners, Config),
    NonConsensusMiners = proplists:get_value(non_consensus_miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    %% FIXME: really need to be setting the balances elsewhere
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% send some helium tokens from payer to payee
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn, SigFun]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    %% XXX: presumably the transaction wouldn't have made it to the blockchain yet
    %% get the current height here
    Chain2 = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, CurrentHeight} = ct_rpc:call(Payer, blockchain, height, [Chain2]),

    %% Wait for an election (should happen at block 6 ideally)
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->
                                      C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                      {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C]),
                                      Height >= CurrentHeight + 10
                              end,
                              Miners
                             )
           end,
           60,
           timer:seconds(1)
          ),

    %% Check that the election txn is in the same block as the rewards txn
    ok = lists:foreach(fun(Miner) ->
                               Chain0 = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                               lists:any(
                                 fun(H) ->
                                         try
                                             {ok, ElectionRewardBlock} = ct_rpc:call(Miner, blockchain, get_block, [H, Chain0]),
                                             Txns = ct_rpc:call(Miner, blockchain_block, transactions, [ElectionRewardBlock]),
                                             ?assertEqual(length(Txns), 2),
                                             [First, Second] = Txns,
                                             ?assertEqual(blockchain_txn:type(Second), blockchain_txn_consensus_group_v1),
                                             ?assertEqual(blockchain_txn:type(First), blockchain_txn_rewards_v1),
                                             Rewards = blockchain_txn_rewards_v1:rewards(First),
                                             ?assertEqual(length(Rewards), length(ConsensusMiners)),
                                             lists:foreach(fun(R) ->
                                                                   ?assertEqual(blockchain_txn_reward_v1:type(R), consensus),
                                                                   ?assertEqual(blockchain_txn_reward_v1:amount(R), 83)
                                                           end,
                                                           Rewards),
                                             true
                                         catch _:_ ->
                                                 false
                                         end
                                 end, lists:seq(4, 10))
                       end,
                       Miners),

    %% Check that the rewards have been paid out
    ok = lists:foreach(fun(Miner) ->
                               Addr = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
                               Bal = miner_ct_utils:get_balance(Miner, Addr),

                               case {Addr == PayerAddr,
                                     Addr == PayeeAddr,
                                     lists:member(Miner, ConsensusMiners),
                                     lists:member(Miner, NonConsensusMiners)} of
                                   {true, _, true, _} ->
                                       ?assertEqual(4138, Bal);
                                   {true, _, _, true} ->
                                       ?assertEqual(4000, Bal);
                                   {_, true, true, _} ->
                                       ?assertEqual(6138, Bal);
                                   {_, true, _, true} ->
                                       ?assertEqual(6000, Bal);
                                   {_, _, true, _} ->
                                       ?assertEqual(5138, Bal);
                                   _ ->
                                       ?assertEqual(5000, Bal)
                               end

                       end,
                       Miners),

    ok.
