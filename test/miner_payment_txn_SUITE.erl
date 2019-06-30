-module(miner_payment_txn_SUITE).

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
         single_payment_test/1,
         self_payment_test/1
        ]).

%% common test callbacks

all() -> [
          single_payment_test,
          self_payment_test
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
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, undefined, 0) || Addr <- Addresses],

    N = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),
    %% VarCommitInterval = proplists:get_value(var_commit_interval, Config),

    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars = #{block_time => BlockTime,
             election_interval => Interval,
             election_restart_interval => 10,
             num_consensus_members => N,
             batch_size => BatchSize,
             vars_commit_interval => 2,
             block_version => v1,
             dkg_curve => Curve,
             proposal_threshold => 0.85,
             election_selection_pct => 60,
             election_replacement_factor => 4},

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),
    KeyProof = blockchain_txn_vars_v1:create_proof(Priv, Vars),

    ct:pal("master key ~p~n priv ~p~n vars ~p~n keyproof ~p~n artifact ~p",
           [BinPub, Priv, Vars, KeyProof,
            term_to_binary(Vars, [{compressed, 9}])]),

    InitialVars = [ blockchain_txn_vars_v1:new(Vars, <<>>, #{master_key => BinPub,
                                                             key_proof => KeyProof}) ],

    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [InitialVars ++ InitialPaymentTransactions ++ AddGwTxns, Addresses,
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

    %% get the genesis block from the first Consensus Miner
    ConsensusMiner = hd(lists:filtermap(fun(Miner) ->
                                                true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                        end, Miners)),
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

    Config.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

single_payment_test(Config) ->
    Miners = proplists:get_value(miners, Config),
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

    %% wait until all the nodes agree the payment has happened
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->
                                      4000 == miner_ct_utils:get_balance(Miner, PayerAddr) + Fee andalso
                                      6000 == miner_ct_utils:get_balance(Miner, PayeeAddr)
                              end,
                              Miners
                             )
           end,
           60,
           timer:seconds(1)
          ),

    PayerBalance = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance = miner_ct_utils:get_balance(Payee, PayeeAddr),

    4000 = PayerBalance + Fee,
    6000 = PayeeBalance,

    %% put the transaction into and then suspend one of the consensus group members
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 2]),

    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),

    %ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn2]),

    [Candidate|_] = lists:filter(fun(Miner) ->
                                         ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                 end, Miners),
    Group = ct_rpc:call(Candidate, gen_server, call, [miner, consensus_group, infinity]),
    false = Group == undefined,
    ok = libp2p_group_relcast:handle_command(Group, SignedTxn2),
    ct_rpc:call(Candidate, sys, suspend, [Group]),

    {ok, CurrentHeight2} = ct_rpc:call(Payer, blockchain, height, [Chain]),

    %% XXX: wait till the blockchain grows by 1 block
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->
                                      C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                      {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C]),
                                      Height >= CurrentHeight2 + 1
                              end,
                              Miners -- [Candidate]
                             )
           end,
           60,
           timer:seconds(1)
          ),

    %% the transaction should not have cleared
    PayerBalance2 = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance2 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    4000 = PayerBalance2 + Fee,
    6000 = PayeeBalance2,

    ct_rpc:call(Candidate, sys, resume, [Group]),

    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->

                                      %% the transaction should have cleared
                                      PayerBalance3 = miner_ct_utils:get_balance(Miner, PayerAddr),
                                      PayeeBalance3 = miner_ct_utils:get_balance(Miner, PayeeAddr),

                                      3000 == PayerBalance3 + Fee andalso
                                      7000 == PayeeBalance3
                              end,
                              Miners
                             )
           end,
           60,
           timer:seconds(1)
          ),
    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.

self_payment_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = PayerAddr,

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

    %% XXX: wait till the blockchain grows by 2 blocks
    %% assuming that the transaction makes it within 2 blocks
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true =:= lists:all(
                              fun(Miner) ->
                                      C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                      {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C]),
                                      Height >= CurrentHeight + 2
                              end,
                              Miners
                             )
           end,
           60,
           timer:seconds(1)
          ),

    PayerBalance = miner_ct_utils:get_balance(Payer, PayerAddr),
    PayeeBalance = miner_ct_utils:get_balance(Payee, PayeeAddr),

    %% No change in balances since the payment should have failed, fee=0 anyway
    5000 = PayerBalance + Fee,
    5000 = PayeeBalance,

    ct:comment("FinalPayerBalance: ~p, FinalPayeeBalance: ~p", [PayerBalance, PayeeBalance]),
    ok.
