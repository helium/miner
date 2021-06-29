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

    Miner1 = hd(Miners),
    ct:pal("Miner1: ~p", [Miner1]),

    Lora = ct_rpc:call(Miner1, sys, get_state, [miner_lora], 500),
    ct:pal("Lora: ~p", [Lora]),

    Region = ct_rpc:call(Miner1, miner_lora, region, [], 500),
    ct:pal("Region: ~p", [Region]),

    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
extra_vars() ->
    ExistingVars = miner_ct_utils:existing_vars(),
    POCV11Vars = miner_poc_test_utils:poc_v11_vars(),
    maps:merge(ExistingVars, POCV11Vars).
