-module(miner_lora_SUITE).

-include_lib("eunit/include/eunit.hrl").
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

    Chain = ct_rpc:call(Miner1, blockchain_worker, blockchain, [], RPCTimeout),

    %% wait until height has increased from 1 to 3
    case miner_ct_utils:wait_for_gte(height, Miners, 1 + 2, any, 30) of
        ok ->
            ok;
        _ ->
            [
                begin
                    Status = ct_rpc:call(M, miner, hbbft_status, []),
                    ct:pal("miner ~p, status: ~p", [M, Status])
                end
             || M <- Miners
            ],
            error(rescue_group_made_no_progress)
    end,

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

    Fee = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        calculate_fee,
        [Txn0, Chain],
        RPCTimeout
    ),

    SFee = ct_rpc:call(
        Miner1,
        blockchain_txn_assert_location_v2,
        calculate_staking_fee,
        [Txn0, Chain],
        RPCTimeout
    ),

    Txn1 = blockchain_txn_assert_location_v2:fee(Txn0, Fee),
    Txn2 = blockchain_txn_assert_location_v2:staking_fee(Txn1, SFee),

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
            Loc == NewLoc
        end,
        30,
        2000
    ),

    %% miner_lora should report the correct region
    Res = ct_rpc:call(Miner1, miner_lora, region, [], RPCTimeout),
    ct:pal("loc: ~p, miner_lora reported: ~p", [NewLoc, Res]),

    ?assertEqual({ok, region_us915}, Res),

    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
extra_vars() ->
    ExistingVars = miner_ct_utils:existing_vars(),
    OverwriteVars = #{block_time => 1000, num_consensus_members => 7},
    POCV11Vars = miner_poc_test_utils:poc_v11_vars(),
    maps:merge(maps:merge(ExistingVars, OverwriteVars), POCV11Vars).
