-module(miner_txn_bundle_SUITE).

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
         single_txn_bundle_test/1
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
          single_txn_bundle_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    Balance = 5000,
    InitialCoinbaseTxns = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    CoinbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    NewConfig = [{rpc_timeout, timer:seconds(5)} | Config],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    N = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    %% Don't want an election to happen, messes up checking the balances later
    Interval = 100,
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
                                       [InitialVars ++ InitialCoinbaseTxns ++ CoinbaseDCTxns ++ AddGwTxns, Addresses,
                                        N, Curve])
                   end, Miners),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    GenesisBlock = get_genesis_block(Miners, NewConfig),

    ok = load_genesis_block(GenesisBlock, Miners, NewConfig),

    NewConfig.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

basic_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),
    %% Create second payment txn
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 2]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),
    %% Create bundle
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1, SignedTxn2]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),
    %% Submit the bundle txn
    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [BundleTxn]),
    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    3000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    7000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

negative_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create second payment txn
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 2]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),

    %% Create bundle with txns reversed, ideally making it invalid
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn2, SignedTxn1]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    %% the balances should not have changed since the bundle was invalid
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

double_spend_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee, Other | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),
    OtherAddr = ct_rpc:call(Other, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),
    5000 = miner_ct_utils:get_balance(Other, OtherAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create second payment txn, where payer is trying to double spend (same nonce).
    Txn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, OtherAddr, 1000, Fee, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn2 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn2, SigFun]),
    ct:pal("SignedTxn2: ~p", [SignedTxn2]),

    %% Create bundle with txns reversed, ideally making it invalid
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1, SignedTxn2]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

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
    Miners = proplists:get_value(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(MinerA, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 5000, Fee, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, Fee, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnBToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

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
    Miners = proplists:get_value(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(MinerA, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 4000, Fee, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, Fee, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnBToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    %% Expectation is that the invalid successive transactions should not go through
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

single_payer_test(Config) ->
    %% Test a bundled payment from single payer
    %% A -> B 2000
    %% A -> C 3000
    Miners = proplists:get_value(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(MinerA, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 2000, Fee, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerCPubkeyBin, 3000, Fee, 2]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToC, SigFunA]),
    ct:pal("SignedTxnAToC: ~p", [SignedTxnAToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnAToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    %% Expectation is that the payments should go through
    0 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    7000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    8000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

single_payer_invalid_test(Config) ->
    %% Test a bundled payment from single payer
    %% A -> B 2000
    %% A -> C 4000
    Miners = proplists:get_value(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(MinerA, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 2000, Fee, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerCPubkeyBin, 4000, Fee, 2]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToC = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToC, SigFunA]),
    ct:pal("SignedTxnAToC: ~p", [SignedTxnAToC]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedTxnAToB, SignedTxnAToC]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

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
    Miners = proplists:get_value(miners, Config),
    [MinerA, MinerB, MinerC | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),
    MinerBPubkeyBin = ct_rpc:call(MinerB, blockchain_swarm, pubkey_bin, []),
    MinerCPubkeyBin = ct_rpc:call(MinerC, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    5000 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(MinerA, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn from A -> B
    TxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, new, [MinerAPubkeyBin, MinerBPubkeyBin, 5000, Fee, 1]),
    {ok, _PubkeyA, SigFunA, _ECDHFunA} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),
    SignedTxnAToB = ct_rpc:call(MinerA, blockchain_txn_payment_v1, sign, [TxnAToB, SigFunA]),
    ct:pal("SignedTxnAToB: ~p", [SignedTxnAToB]),

    %% Create second payment txn from B -> C
    TxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerBPubkeyBin, MinerCPubkeyBin, 10000, Fee, 1]),
    {ok, _PubkeyB, SigFunB, _ECDHFunB} = ct_rpc:call(MinerB, blockchain_swarm, keys, []),
    SignedTxnBToC = ct_rpc:call(MinerB, blockchain_txn_payment_v1, sign, [TxnBToC, SigFunB]),
    ct:pal("SignedTxnBToC: ~p", [SignedTxnBToC]),

    %% Create third payment txn from C -> A
    TxnCToA = ct_rpc:call(MinerB, blockchain_txn_payment_v1, new, [MinerCPubkeyBin, MinerAPubkeyBin, 15000, Fee, 1]),
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
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    %% Expectation is that the full payment circle should complete
    15000 = miner_ct_utils:get_balance(MinerA, MinerAPubkeyBin),
    0 = miner_ct_utils:get_balance(MinerB, MinerBPubkeyBin),
    0 = miner_ct_utils:get_balance(MinerC, MinerCPubkeyBin),

    ok.

add_assert_test(Config) ->
    %% Test add + assert in a bundled txn
    %% A -> [add_gateway, assert_location]
    Miners = proplists:get_value(miners, Config),
    [MinerA | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),

    {ok, _OwnerPubkey, OwnerSigFun, _OwnerECDHFun} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),

    %% Create add_gateway txn
    [{GatewayPubkeyBin, {_GatewayPubkey, _GatewayPrivkey, GatewaySigFun}}] = miner_ct_utils:generate_keys(1),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(MinerAPubkeyBin, GatewayPubkeyBin, 1, 0),
    SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
    SignedAddGatewayTxn = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
    ct:pal("SignedAddGatewayTxn: ~p", [SignedAddGatewayTxn]),

    %% Create assert loc txn
    Index = 631210968910285823,
    AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, Index, 1, 1, 0),
    PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
    SignedAssertLocationTxn = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
    ct:pal("SignedAssertLocationTxn: ~p", [SignedAssertLocationTxn]),

    %% Create bundle with txns
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedAddGatewayTxn, SignedAssertLocationTxn]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height 20, should be long enough I believe
    ok = wait_until_height(Miners, 20),

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
    Miners = proplists:get_value(miners, Config),
    [MinerA | _Tail] = Miners,
    MinerAPubkeyBin = ct_rpc:call(MinerA, blockchain_swarm, pubkey_bin, []),

    {ok, _OwnerPubkey, OwnerSigFun, _OwnerECDHFun} = ct_rpc:call(MinerA, blockchain_swarm, keys, []),

    %% Create add_gateway txn
    [{GatewayPubkeyBin, {_GatewayPubkey, _GatewayPrivkey, GatewaySigFun}}] = miner_ct_utils:generate_keys(1),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(MinerAPubkeyBin, GatewayPubkeyBin, 1, 0),
    SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
    SignedAddGatewayTxn = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
    ct:pal("SignedAddGatewayTxn: ~p", [SignedAddGatewayTxn]),

    %% Create assert loc txn
    Index = 631210968910285823,
    AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(GatewayPubkeyBin, MinerAPubkeyBin, Index, 1, 1, 0),
    PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
    SignedAssertLocationTxn = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
    ct:pal("SignedAssertLocationTxn: ~p", [SignedAssertLocationTxn]),

    %% Create bundle with txns in bad order
    BundleTxn = ct_rpc:call(MinerA, blockchain_txn_bundle_v1, new, [[SignedAssertLocationTxn, SignedAddGatewayTxn]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),

    %% Submit the bundle txn
    ok = ct_rpc:call(MinerA, blockchain_worker, submit_txn, [BundleTxn]),

    %% wait till height 20, should be long enough I believe
    ok = wait_until_height(Miners, 20),

    %% Get active gateways
    Chain = ct_rpc:call(MinerA, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(MinerA, blockchain, ledger, [Chain]),
    ActiveGateways = ct_rpc:call(MinerA, blockchain_ledger_v1, active_gateways, [Ledger]),

    %% Check that the gateway did not get added
    8 = maps:size(ActiveGateways),

    ok.

single_txn_bundle_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    [Payer, Payee | _Tail] = Miners,
    PayerAddr = ct_rpc:call(Payer, blockchain_swarm, pubkey_bin, []),
    PayeeAddr = ct_rpc:call(Payee, blockchain_swarm, pubkey_bin, []),

    %% check initial balances
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayerAddr),

    Chain = ct_rpc:call(Payer, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Payer, blockchain, ledger, [Chain]),

    {ok, Fee} = ct_rpc:call(Payer, blockchain_ledger_v1, transaction_fee, [Ledger]),

    %% Create first payment txn
    Txn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, new, [PayerAddr, PayeeAddr, 1000, Fee, 1]),
    {ok, _Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Payer, blockchain_swarm, keys, []),
    SignedTxn1 = ct_rpc:call(Payer, blockchain_txn_payment_v1, sign, [Txn1, SigFun]),
    ct:pal("SignedTxn1: ~p", [SignedTxn1]),

    %% Create bundle
    BundleTxn = ct_rpc:call(Payer, blockchain_txn_bundle_v1, new, [[SignedTxn1]]),
    ct:pal("BundleTxn: ~p", [BundleTxn]),
    %% Submit the bundle txn
    ok = ct_rpc:call(Payer, blockchain_worker, submit_txn, [BundleTxn]),
    %% wait till height is 15, ideally should wait till the payment actually occurs
    %% it should be plenty fast regardless
    ok = wait_until_height(Miners, 15),

    %% The bundle is invalid since it does not contain atleast two txns in it
    5000 = miner_ct_utils:get_balance(Payer, PayerAddr),
    5000 = miner_ct_utils:get_balance(Payee, PayeeAddr),

    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

wait_until_height(Miners, Height) ->
    miner_ct_utils:wait_until(
      fun() ->
              Heights = lists:map(fun(Miner) ->
                                          case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
                                              undefined -> -1;
                                              {badrpc, _} -> -1;
                                              C ->
                                                  {ok, H} = ct_rpc:call(Miner, blockchain, height, [C]),
                                                  H
                                          end
                                  end,
                                  Miners),
              ct:pal("Heights: ~w", [Heights]),

              true == lists:all(fun(H) ->
                                        H >= Height
                                end,
                                Heights)
      end,
      60,
      timer:seconds(5)).

get_genesis_block(Miners, Config) ->
    RPCTimeout = proplists:get_value(rpc_timeout, Config),
    %% obtain the genesis block
    GenesisBlock = get_genesis_block_(Miners, RPCTimeout),
    ?assertNotEqual(undefined, GenesisBlock),
    GenesisBlock.

get_genesis_block_([Miner|Miners], RPCTimeout) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, [], RPCTimeout) of
        {badrpc, Reason} ->
            ct:fail(Reason),
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        undefined ->
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        Chain ->
            {ok, GBlock} = rpc:call(Miner, blockchain, genesis_block, [Chain], RPCTimeout),
            GBlock
    end.

load_genesis_block(GenesisBlock, Miners, Config) ->
    RPCTimeout = proplists:get_value(rpc_timeout, Config),
    %% load the genesis block on all the nodes
    lists:foreach(
        fun(Miner) ->
                case ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], RPCTimeout) of
                    true ->
                        ok;
                    false ->
                        Res = ct_rpc:call(Miner, blockchain_worker,
                                          integrate_genesis_block, [GenesisBlock], RPCTimeout),
                        ct:pal("loading genesis ~p block on ~p ~p", [GenesisBlock, Miner, Res])
                end
        end,
        Miners
    ),

    timer:sleep(5000),

    ok = wait_until_height(Miners, 1).
