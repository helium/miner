%%% RELOC MOVE to core
-module(miner_reward_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

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
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    InitialCoinbaseTxns = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    Interval = 5,
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialVars ++ InitialCoinbaseTxns ++ AddGwTxns,
                                            Addresses, NumConsensusMembers, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    ok = miner_ct_utils:wait_for_in_consensus(Miners, NumConsensusMembers),

    %% Get non consensus miners
    NonConsensusMiners = miner_ct_utils:non_consensus_miners(Miners),

    %% ensure that blockchain is undefined for non_consensus miners
    false = miner_ct_utils:blockchain_worker_check(NonConsensusMiners),

    %% Get consensus miners
    ConsensusMiners = miner_ct_utils:in_consensus_miners(Miners),

   
    %% confirm height is 1
    ok = miner_ct_utils:wait_for_gte(height, Miners, 2),

    [   {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners} | Config]
    catch
        What:Why ->
            end_per_testcase(_TestCase, Config),
            erlang:What(Why)
    end.


end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),
    NonConsensusMiners = ?config(non_consensus_miners, Config),

    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    %% FIXME: really need to be setting the balances elsewhere
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    %% send some helium tokens from payer to payee
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn, SigFun]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    %% Wait for an election (should happen at block 6 ideally)
    miner_ct_utils:wait_for_gte(epoch, Miners, 2),

    %% TODO: this code is currently a noop because assertions are
    %% exceptions.  we should be using chain information to figure
    %% this out: we don't need to do it for each miner, we just need
    %% to make sure that 1) we know what the election block is and
    %% that its txns looks correct and 2) and then not go to the
    %% cluster for balances.

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
                                 end, lists:seq(5, 15))
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


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
