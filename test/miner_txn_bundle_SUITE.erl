-module(miner_txn_bundle_SUITE).

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
         negative_test/1,
         double_spend_test/1,
         successive_test/1,
         invalid_successive_test/1,
         single_payer_test/1,
         single_payer_invalid_test/1,
         full_circle_test/1,
         add_assert_test/1,
         invalid_add_assert_test/1,
         transfer_hotspot_test/1,
         single_txn_bundle_test/1,
         bundleception_test/1
        ]).

%% common test callbacks

all() -> [
          basic_test,
          negative_test,
          double_spend_test,
          successive_test,
          invalid_successive_test,
          single_payer_test,
          single_payer_invalid_test,
          full_circle_test,
          add_assert_test,
          invalid_add_assert_test,
          transfer_hotspot_test,
          single_txn_bundle_test,
          bundleception_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Balance = 5000,
    InitialCoinbaseTxns = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    CoinbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    NewConfig = [{rpc_timeout, timer:seconds(5)} | Config],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers= ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    %% Don't want an election to happen, messes up checking the balances later
    Interval = 100,
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    DKGResults = miner_ct_utils:initial_dkg(Miners, InitialVars ++ InitialCoinbaseTxns ++ CoinbaseDCTxns ++ AddGwTxns,
                                    Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),
    [
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | NewConfig].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),
    %% Create second payment txn
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 2]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),
    %% Create bundle
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1, SignedTxn2]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),
    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),
    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    3000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    7000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

negative_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create second payment txn
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 2]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),

    %% Create bundle with txns reversed, ideally making it invalid
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn2, SignedTxn1]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% the balances should not have changed since the bundle was invalid
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

double_spend_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee, Other | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    OtherAddr = ct_rpc:call(Other, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),
    5000 = miner_ct_utils:get_balance(Other, OtherAddr),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create second payment txn, where payer is trying to double spend (same nonce).
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, OtherAddr, 1000, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),

    %% Create bundle with txns reversed, ideally making it invalid
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1, SignedTxn2]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% the balances should not have changed since the bundle was invalid
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),
    5000 = miner_ct_utils:get_balance(Other, OtherAddr),

    ok.

successive_test(Config) ->
    %% Test a successive valid bundle payment
    %% A -> B -> C
    %% A -> B 5000
    %% B -> C 10000
    Miners = ?config(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 5000, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnBToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Expectation is that the successive transactions should go through
    0 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    0 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    15000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

invalid_successive_test(Config) ->
    %% Test a successive invalid bundle payment
    %% A -> B -> C
    %% A -> B 4000
    %% B -> C 10000 <-- this is invalid
    Miners = ?config(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 4000, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnBToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Expectation is that the invalid successive transactions should not go through
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

single_payer_test(Config) ->
    %% Test a bundled payment from single payer
    %% A -> B 2000
    %% A -> C 3000
    Miners = ?config(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 2000, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerCPubkeyBin, 3000, 2]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToC, SigFunA]),
    ct:pal("SignedTxnAToC: ~p", [SignedTxnAToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnAToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Expectation is that the payments should go through
    0 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    7000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    8000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

single_payer_invalid_test(Config) ->
    %% Test a bundled payment from single payer
    %% A -> B 2000
    %% A -> C 4000
    Miners = ?config(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 2000, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerCPubkeyBin, 4000, 2]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToC, SigFunA]),
    ct:pal("SignedTxnAToC: ~p", [SignedTxnAToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnAToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Expectation is that the payments should not go through
    %% because A is trying to over-spend
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

full_circle_test(Config) ->
    %% Test a successive valid bundle payment
    %% A -> B -> C
    %% A -> B 5000
    %% B -> C 10000
    Miners = ?config(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 5000, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create third payment txn from C -> A
    TxnCToA = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerCPubkeyBin, MinerAPubkeyBin, 15000, 1]),
    {ok, _PubkeyC, SigFunC, _ECDHFunC} = ct_rpc:call(MinerC, blockchain_swarm, keys, []),
    SignedTxnCToA = ct_rpc:call(MinerC, blockchain_txn_payment_v1, sign, [TxnCToA, SigFunC]),
    ct:pal("SignedTxnCToA: ~p", [SignedTxnCToA]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB,
                                                                     SignedTxnBToC,
                                                                     SignedTxnCToA
                                                                    ]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Expectation is that the full payment circle should complete
    15000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    0 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    0 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

add_assert_test(Config) ->
    %% Test add + assert in a bundled txn
    %% A -> [add_gateway, assert_location]
    Miners = ?config(miners, Config),
    [MinerA | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),

    {ok, _OwnerPubkey, OwnerSigFun, _OwnerECDHFun} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),

    %% Create add_gateway txn
    [{GatewayPubkeyBin, {_GatewayPubkey, _GatewayPrivkey, GatewaySigFun}}] = miner_ct_utils:generate_keys(1),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(MinerAPubkeyBin, GatewayPubkeyBin),
    SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
    SignedAddGatewayTxn = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
    ct:pal("SignedAddGatewayTxn: ~p", [SignedAddGatewayTxn]),

    %% Create assert loc txn
    Index = 631210968910285823,
    AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, Index, 1),
    PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
    SignedAssertLocationTxn = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
    ct:pal("SignedAssertLocationTxn: ~p", [SignedAssertLocationTxn]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedAddGatewayTxn, SignedAssertLocationTxn]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height 20, should be long enough I believe
    ok = miner_ct_utils:wait_for_gte(height, Miners, 20),

    %% Get active gateways
    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),
    ActiveGateways = ct_rpc:call(MinerA, blockchain_ledger_v1, active_gateways, [Ledger]),

    %% Check that the gateway got added
    9 = maps:size(ActiveGateways),

    %% Check that it has the correct location
    AddedGw = maps:get(GatewayPubkeyBin, ActiveGateways),
    GwLoc = blockchain_ledger_gateway_v2:location(AddedGw),
    ?assertEqual(GwLoc, Index),

    ok.

invalid_add_assert_test(Config) ->
    %% Test add + assert in a bundled txn
    %% A -> [add_gateway, assert_location]
    Miners = ?config(miners, Config),
    [MinerA | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),

    {ok, _OwnerPubkey, OwnerSigFun, _OwnerECDHFun} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),

    %% Create add_gateway txn
    [{GatewayPubkeyBin, {_GatewayPubkey, _GatewayPrivkey, GatewaySigFun}}] = miner_ct_utils:generate_keys(1),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(MinerAPubkeyBin, GatewayPubkeyBin),
    SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
    SignedAddGatewayTxn = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
    ct:pal("SignedAddGatewayTxn: ~p", [SignedAddGatewayTxn]),

    %% Create assert loc txn
    Index = 631210968910285823,
    AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, Index, 1),
    PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
    SignedAssertLocationTxn = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
    ct:pal("SignedAssertLocationTxn: ~p", [SignedAssertLocationTxn]),

    %% Create bundle with txns in bad order
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedAssertLocationTxn, SignedAddGatewayTxn]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height 20, should be long enough I believe
    ok = miner_ct_utils:wait_for_gte(height, Miners, 20),

    %% Get active gateways
    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),
    ActiveGateways = ct_rpc:call(MinerA, blockchain_ledger_v1, active_gateways, [Ledger]),

    %% Check that the gateway did not get added
    8 = maps:size(ActiveGateways),

    ok.

transfer_hotspot_test(Config) ->
    %% A -> [add_gateway, assert_location]
    %% A -> [transfer_hotspot] to B
    Miners = ?config(miners, Config),
    [MinerA, MinerB | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),

    {ok, _OwnerAPubkey, OwnerASigFun, _OwnerAECDHFun} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    {ok, _OwnerBPubkey, OwnerBSigFun, _OwnerBECDHFun} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),

    %% Create add_gateway txn
    [{GatewayPubkeyBin, {_GatewayPubkey, _GatewayPrivkey, GatewaySigFun}}] = miner_ct_utils:generate_keys(1),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(MinerAPubkeyBin, GatewayPubkeyBin),
    SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerASigFun),
    SignedAddGatewayTxn = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
    ct:pal("SignedAddGatewayTxn: ~p", [SignedAddGatewayTxn]),

    %% Create assert loc txn
    Index = 631210968910285823,
    AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, Index, 1),
    PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
    SignedAssertLocationTxn = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerASigFun),
    ct:pal("SignedAssertLocationTxn: ~p", [SignedAssertLocationTxn]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedAddGatewayTxn, SignedAssertLocationTxn]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),

    %% wait till height 10 for txn to clear
    ok = miner_ct_utils:wait_for_gte(height, Miners, 10),

    %% Get active gateways
    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),
    ActiveGateways = ct_rpc:call(MinerA, blockchain_ledger_v1, active_gateways, [Ledger]),

    %% Check that the gateway got added
    9 = maps:size(ActiveGateways),

    %% validate initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),

    %% create transfer hotspot txn
    TransferTxn = blockchain_txn_transfer_hotspot_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, MinerBPubkeyBin, 1000),
    SellerXferSigned = blockchain_txn_transfer_hotspot_v1:sign_seller(TransferTxn, OwnerASigFun),
    BuyerXferSigned = blockchain_txn_transfer_hotspot_v1:sign_buyer(SellerXferSigned, OwnerBSigFun),
    ct:pal("BuyerXferSigned: ~p", [BuyerXferSigned]),

    miner_ct_utils:submit_txn(BuyerXferSigned, Miners),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 20),

    Chain0 = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger0 = ct_rpc:call(MinerA, blockchain, ledger, [Chain0]),
    ActiveGateways0 = ct_rpc:call(MinerA, blockchain_ledger_v1, active_gateways, [Ledger0]),

    XferGw = maps:get(GatewayPubkeyBin, ActiveGateways0),
    ?assertEqual(MinerBPubkeyBin, blockchain_ledger_gateway_v2:owner_address(XferGw)),
    ?assertEqual(6000, miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin)),
    ?assertEqual(4000, miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin)),
    ok.

single_txn_bundle_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create bundle
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),
    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleTxn, Miners),
    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% The bundle is invalid since it does not contain atleast two txns in it
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

bundleception_test(Config) ->
    Miners = ?config(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    %% Payer Sigfun
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),

    %% --------------------------------------------------------------
    %% Bundle 1 contents
    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 1]),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create second payment txn
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 2]),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),

    %% Create bundle
    BundleTxn1 = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1, SignedTxn2]]),
    ct:pal("BundleTxn1: ~p", [BundleTxn1]),
    %% --------------------------------------------------------------

    %% --------------------------------------------------------------
    %% Bundle 2 contents
    %% Create third payment txn
    Txn3 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 3]),
    SignedTxn3 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn3, SigFun]),
    ct:pal("SignedTxn3: ~p", [SignedTxn3]),

    %% Create fourth payment txn
    Txn4 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, 4]),
    SignedTxn4 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn4, SigFun]),
    ct:pal("SignedTxn4: ~p", [SignedTxn4]),

    %% Create bundle
    BundleTxn2 = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn3, SignedTxn4]]),
    ct:pal("BundleTxn2: ~p", [BundleTxn2]),
    %% --------------------------------------------------------------


    %% Do bundleception
    BundleInBundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[BundleTxn1, BundleTxn2]]),
    ct:pal("BundleInBundleTxn: ~p", [BundleInBundleTxn]),

    %% Submit the bundle txn
    miner_ct_utils:submit_txn(BundleInBundleTxn, Miners),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),

    %% Balances should not have changed
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------




