-module(miner_payment_v2_txn_SUITE).

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
         basic_test/1,
         zero_amt_test/1
        ]).

%% common test callbacks

all() -> [
          basic_test,
          zero_amt_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    %% VarCommitInterval = ?config(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   %% rule out rewards
                                                   ?election_interval => infinity,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve,
                                                   ?max_payments => 10,
                                                   ?allow_zero_amount => false}),

    DKGResults = miner_ct_utils:initial_dkg(Miners, InitialVars ++ InitialPaymentTransactions ++ AddGwTxns,
                                           Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 2),

    [   {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config].


end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    _ConsensusMiners = ?config(consensus_miners, Config),
    [Payer | Payees] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),

    PayeeAddrs = lists:foldl(fun(Payee, Acc) ->
                                     PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
                                     [PayeeAddr | Acc]
                             end,
                             [],
                             Payees),

    ct:pal("PayeeAddrs: ~p", [PayeeAddrs]),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    ok = lists:foreach(fun({Payee, PayeeAddr}) ->
                               5000 = miner_ct_utils:get_balance(Payee, PayeeAddr)
                       end,
                       lists:zip(Payees, PayeeAddrs)),

    %% send some helium tokens from payer to payees
    PayeeAmount = 100,
    Payments = [blockchain_payment_v2:new(P, PayeeAmount) || P <- PayeeAddrs],
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v2, new, [PayerAddr, Payments, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v2, sign, [Txn, SigFun]),
    ct:pal("SignedTxn: ~p", [SignedTxn]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    ok = lists:foreach(fun(M) ->
                               A = ct_rpc:call(M, blockchain_swarm, pubkey_bin, []),
                               ct:pal("Addr: ~p, Balance: ~p", [A, miner_ct_utils:get_balance(M, A)])
                       end,
                       Miners),

    %% wait until all the nodes agree the payment has happened
    %% NOTE: Fee is zero
    ok = miner_ct_utils:confirm_balance(Miners, PayerAddr, (5000 - (length(Payees)*PayeeAmount))),

    ok = lists:foreach(fun(PayeeAddr) ->
                               ok = miner_ct_utils:confirm_balance(Miners, PayeeAddr, 5000 + PayeeAmount)
                       end,
                       PayeeAddrs),

    %% Print for verification
    ok = lists:foreach(fun(M) ->
                               A = ct_rpc:call(M, blockchain_swarm, pubkey_bin, []),
                               ct:pal("Addr: ~p, Balance: ~p", [A, miner_ct_utils:get_balance(M, A)])
                       end,
                       Miners),

    ok.

zero_amt_test(Config) ->
    Miners = ?config(miners, Config),
    _ConsensusMiners = ?config(consensus_miners, Config),
    [Payer | Payees] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),

    PayeeAddrs = lists:foldl(fun(Payee, Acc) ->
                                     PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
                                     [PayeeAddr | Acc]
                             end,
                             [],
                             Payees),

    ct:pal("PayeeAddrs: ~p", [PayeeAddrs]),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    ok = lists:foreach(fun({Payee, PayeeAddr}) ->
                               5000 = miner_ct_utils:get_balance(Payee, PayeeAddr)
                       end,
                       lists:zip(Payees, PayeeAddrs)),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(Payer, blockchain, height, [Chain]),

    %% send 0 amount
    PayeeAmount = 0,
    Payments = [blockchain_payment_v2:new(P, PayeeAmount) || P <- PayeeAddrs],
    Txn = ct_rpc:call(Payer, blockchain_txn_payment_v2, new, [PayerAddr, Payments, 1]),

    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    SignedTxn = ct_rpc:call(Payer, blockchain_txn_payment_v2, sign, [Txn, SigFun]),
    ct:pal("SignedTxn: ~p", [SignedTxn]),

    {error, invalid_transaction} = ct_rpc:call(Payer, blockchain_txn, is_valid, [SignedTxn, Chain]),

    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [SignedTxn]),

    %% Wait 10 blocks after submission
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 10),

    %% wait until all the nodes agree that balance has not changed
    ok = lists:foreach(fun(PayeeAddr) ->
                               ok = miner_ct_utils:confirm_balance(Miners, PayeeAddr, 5000)
                       end,
                       PayeeAddrs),

    %% Print for verification
    ok = lists:foreach(fun(M) ->
                               A = ct_rpc:call(M, blockchain_swarm, pubkey_bin, []),
                               ct:pal("Addr: ~p, Balance: ~p", [A, miner_ct_utils:get_balance(M, A)])
                       end,
                       Miners),

    ok.
