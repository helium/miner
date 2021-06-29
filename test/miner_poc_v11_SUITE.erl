-module(miner_poc_v11_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([
    all/0
]).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    basic_test/1
]).

all() ->
    [
        basic_test
    ].

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    Config1 = miner_ct_utils:start_blockchain(Config, extra_vars()),

    %% NOTE: keys in the config
    %% [master_key, consensus_miners, non_consensus_miners, miners, keys, ports,
    %% node_options, addresses, tagged_addresses, block_time, batch_size, dkg_curve,
    %% election_interval, rpc_timeout, base_dir, log_dir, watchdog, tc_logfile,
    %% tc_group_properties, tc_group_path, data_dir, priv_dir]
    Config1.

end_per_testcase(_TestCase, Config) ->
    catch gen_statem:stop(miner_poc_statem),
    catch gen_server:stop(miner_fake_radio_backplane),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            BaseDir = ?config(base_dir, Config),
            os:cmd("rm -rf " ++ BaseDir),
            ok;
        _ ->
            %% leave results alone for analysis
            ok
    end.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
basic_test(Config) ->
    Miners = ?config(miners, Config),
    RPCTimeout = ?config(rpc_timeout, Config),

    Miner1 = hd(Miners),
    ct:pal("Miner1: ~p", [Miner1]),

    Lora = ct_rpc:call(Miner1, sys, get_state, [miner_lora], RPCTimeout),
    ct:pal("Lora: ~p", [Lora]),

    Region = ct_rpc:call(Miner1, miner_lora, region, [], RPCTimeout),
    ct:pal("Region: ~p", [Region]),

    Chain = ct_rpc:call(Miner1, blockchain_worker, blockchain, [], RPCTimeout),
    ct:pal("Chain: ~p", [Chain]),

    %% For tests: GatewayPubkeyBin = Miner1PubkeyBin = OwnerPubkeyBin = PayerPubkeyBin
    Miner1PubkeyBin = ct_rpc:call(Miner1, blockchain_swarm, pubkey_bin, [], RPCTimeout),

    %% For tests: GatewayPubkeyBin = Miner1PubkeyBin = OwnerPubkeyBin = PayerPubkeyBin
    {ok, _, Miner1SigFun, _} = ct_rpc:call(Miner1, blockchain_swarm, keys, [], RPCTimeout),

    %% assert loc for miner1
    NewLoc = 631252734740306943,
    Txn0 = blockchain_txn_assert_location_v2:new(
        Miner1PubkeyBin,
        Miner1PubkeyBin,
        Miner1PubkeyBin,
        NewLoc,
        1
    ),
    ct:pal("Txn0: ~p", [Txn0]),

    Fee = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        calculate_fee,
        [Txn0, Chain],
        RPCTimeout
    ),
    ct:pal("Fee: ~p", [Fee]),

    SFee = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        calculate_staking_fee,
        [Txn0, Chain],
        RPCTimeout
    ),
    ct:pal("SFee: ~p", [SFee]),

    Txn1 = blockchain_txn_assert_location_v2:fee(Txn0, Fee),
    Txn2 = blockchain_txn_assert_location_v2:staking_fee(Txn1, SFee),
    ct:pal("Txn2: ~p", [Txn2]),

    STxn0 = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        sign,
        [Txn2, Miner1SigFun],
        RPCTimeout
    ),
    STxn1 = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        sign_payer,
        [STxn0, Miner1SigFun],
        RPCTimeout
    ),

    ct:pal("STxn1: ~p", [STxn1]),

    %% check txn is valid?
    ok = ct_rpc:call(Miner1, blockchain_txn, is_valid, [STxn1, Chain], RPCTimeout),

    %% submit txn
    ok = ct_rpc:call(Miner1, blockchain_worker, submit_txn, [STxn1], RPCTimeout),

    %% check that the location changed for miner1
    true = miner_ct_utils:wait_until(
        fun() ->
            L = ct_rpc:call(Miner1, blockchain, ledger, [Chain], RPCTimeout),
            {ok, GW} = ct_rpc:call(
                Miner1,
                blockchain_ledger_v1,
                find_gateway_info,
                [Miner1PubkeyBin, L],
                RPCTimeout
            ),
            Loc = blockchain_ledger_gateway_v2:location(GW),
            Ht = ct_rpc:call(Miner1, blockchain, height, [Chain], RPCTimeout),
            ct:pal(
                "Ht: ~p, GW: ~p, Loc: ~p, NewLoc: ~p",
                [Ht, GW, Loc, NewLoc]
            ),
            Loc == NewLoc
        end,
        120,
        1000
    ),

    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
extra_vars() ->
    ExistingVars = miner_ct_utils:existing_vars(),
    POCV11Vars = miner_poc_test_utils:poc_v11_vars(),
    maps:merge(ExistingVars, POCV11Vars).
