-module(miner_poc_v11_SUITE).

-include_lib("common_test/include/ct.hrl").
%% -include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

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
    miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0).

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
    Res = start_blockchain(Config),
    ct:pal("Res: ~p", [Res]),
    ok.

start_blockchain(Config) ->
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Curve = ?config(dkg_curve, Config),
    NumConsensusMembers = ?config(num_consensus_members, Config),

    #{secret := Priv, public := Pub} =
        Keys =
        libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, extra_vars()),
    InitialPayments = miner_ct_utils:gen_payments(Addresses),
    Locations = gen_locations(Addresses),
    InitialGws = miner_ct_utils:gen_gateways(Addresses, Locations),
    Txns = InitialVars ++ InitialPayments ++ InitialGws,

    ct:pal("Genesis txns: ~p", [Txns]),

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(
        Miners,
        Txns,
        Addresses,
        NumConsensusMembers,
        Curve
    ),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(
        hd(DKGCompletedNodes),
        Miners -- DKGCompletedNodes
    ),
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    [
        {master_key, {Priv, Pub}},
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config
    ].

extra_vars() ->
    POCV11Vars = miner_poc_test_utils:poc_v11_vars(),
    maps:merge(existing_vars(), POCV11Vars).

existing_vars() ->
    #{
        ?allow_payment_v2_memos => true,
        ?allow_zero_amount => false,
        ?alpha_decay => 0.0035,
        ?assert_loc_txn_version => 2,
        ?batch_size => 400,
        ?beta_decay => 0.002,
        ?block_time => 60000,
        ?block_version => v1,
        ?chain_vars_version => 2,
        ?consensus_percent => 0.06,
        ?data_aggregation_version => 2,
        ?dc_payload_size => 24,
        ?dc_percent => 0.325,
        ?density_tgt_res => 4,
        ?dkg_curve => 'SS512',
        ?election_bba_penalty => 0.001,
        ?election_cluster_res => 4,
        ?election_interval => 30,
        ?election_removal_pct => 40,
        ?election_replacement_factor => 4,
        ?election_replacement_slope => 20,
        ?election_restart_interval => 5,
        ?election_seen_penalty => 0.0033333,
        ?election_selection_pct => 1,
        ?election_version => 4,
        ?h3_exclusion_ring_dist => 6,
        ?h3_max_grid_distance => 120,
        ?h3_neighbor_res => 12,
        ?hip17_interactivity_blocks => 3600,
        ?hip17_res_0 => <<"2,100000,100000">>,
        ?hip17_res_1 => <<"2,100000,100000">>,
        ?hip17_res_10 => <<"2,1,1">>,
        ?hip17_res_11 => <<"2,100000,100000">>,
        ?hip17_res_12 => <<"2,100000,100000">>,
        ?hip17_res_2 => <<"2,100000,100000">>,
        ?hip17_res_3 => <<"2,100000,100000">>,
        ?hip17_res_4 => <<"1,250,800">>,
        ?hip17_res_5 => <<"1,100,400">>,
        ?hip17_res_6 => <<"1,25,100">>,
        ?hip17_res_7 => <<"2,5,20">>,
        ?hip17_res_8 => <<"2,1,4">>,
        ?hip17_res_9 => <<"2,1,2">>,
        ?max_antenna_gain => 150,
        ?max_open_sc => 5,
        ?max_payments => 50,
        ?max_staleness => 100000,
        ?max_subnet_num => 5,
        ?max_subnet_size => 65536,
        ?max_xor_filter_num => 5,
        ?max_xor_filter_size => 102400,
        ?min_antenna_gain => 10,
        ?min_assert_h3_res => 12,
        ?min_expire_within => 15,
        ?min_score => 0.15,
        ?min_subnet_size => 8,
        ?monthly_reward => 500000000000000,
        ?num_consensus_members => 16,
        ?poc_addr_hash_byte_count => 8,
        ?poc_centrality_wt => 0.5,
        ?poc_challenge_interval => 480,
        ?poc_challenge_sync_interval => 90,
        ?poc_challengees_percent => 0.0531,
        ?poc_challengers_percent => 0.0095,
        ?poc_good_bucket_high => -70,
        ?poc_good_bucket_low => -130,
        ?poc_max_hop_cells => 2000,
        ?poc_path_limit => 1,
        ?poc_per_hop_max_witnesses => 25,
        ?poc_reward_decay_rate => 0.8,
        ?poc_target_hex_parent_res => 5,
        ?poc_typo_fixes => true,
        ?poc_v4_exclusion_cells => 8,
        ?poc_v4_parent_res => 11,
        ?poc_v4_prob_bad_rssi => 0.01,
        ?poc_v4_prob_count_wt => 0.0,
        ?poc_v4_prob_good_rssi => 1.0,
        ?poc_v4_prob_no_rssi => 0.5,
        ?poc_v4_prob_rssi_wt => 0.0,
        ?poc_v4_prob_time_wt => 0.0,
        ?poc_v4_randomness_wt => 0.5,
        ?poc_v4_target_challenge_age => 1000,
        ?poc_v4_target_exclusion_cells => 6000,
        ?poc_v4_target_prob_edge_wt => 0.0,
        ?poc_v4_target_prob_score_wt => 0.0,
        ?poc_v4_target_score_curve => 5,
        ?poc_v5_target_prob_randomness_wt => 1.0,
        ?poc_version => 10,
        ?poc_witness_consideration_limit => 20,
        ?poc_witnesses_percent => 0.2124,
        ?predicate_callback_fun => version,
        ?predicate_callback_mod => miner,
        ?predicate_threshold => 0.95,
        ?price_oracle_height_delta => 10,
        ?price_oracle_price_scan_delay => 3600,
        ?price_oracle_price_scan_max => 90000,
        ?price_oracle_public_keys =>
            <<33, 1, 32, 30, 226, 70, 15, 7, 0, 161, 150, 108, 195, 90, 205, 113, 146, 41, 110, 194,
                43, 86, 168, 161, 93, 241, 68, 41, 125, 160, 229, 130, 205, 140, 33, 1, 32, 237, 78,
                201, 132, 45, 19, 192, 62, 81, 209, 208, 156, 103, 224, 137, 51, 193, 160, 15, 96,
                238, 160, 42, 235, 174, 99, 128, 199, 20, 154, 222, 33, 1, 143, 166, 65, 105, 75,
                56, 206, 157, 86, 46, 225, 174, 232, 27, 183, 145, 248, 50, 141, 210, 144, 155, 254,
                80, 225, 240, 164, 164, 213, 12, 146, 100, 33, 1, 20, 131, 51, 235, 13, 175, 124,
                98, 154, 135, 90, 196, 83, 14, 118, 223, 189, 221, 154, 181, 62, 105, 183, 135, 121,
                105, 101, 51, 163, 119, 206, 132, 33, 1, 254, 129, 70, 123, 51, 101, 208, 224, 99,
                172, 62, 126, 252, 59, 130, 84, 93, 231, 214, 248, 207, 139, 84, 158, 120, 232, 6,
                8, 121, 243, 25, 205, 33, 1, 148, 214, 252, 181, 1, 33, 200, 69, 148, 146, 34, 29,
                22, 91, 108, 16, 18, 33, 45, 0, 210, 100, 253, 211, 177, 78, 82, 113, 122, 149, 47,
                240, 33, 1, 170, 219, 208, 73, 156, 141, 219, 148, 7, 148, 253, 209, 66, 48, 218,
                91, 71, 232, 244, 198, 253, 236, 40, 201, 90, 112, 61, 236, 156, 69, 235, 109, 33,
                1, 154, 235, 195, 88, 165, 97, 21, 203, 1, 161, 96, 71, 236, 193, 188, 50, 185, 214,
                15, 14, 86, 61, 245, 131, 110, 22, 150, 8, 48, 174, 104, 66, 33, 1, 254, 248, 78,
                138, 218, 174, 201, 86, 100, 210, 209, 229, 149, 130, 203, 83, 149, 204, 154, 58,
                32, 192, 118, 144, 129, 178, 83, 253, 8, 199, 161, 128>>,
        ?price_oracle_refresh_interval => 10,
        ?reward_version => 5,
        ?rewards_txn_version => 2,
        ?sc_causality_fix => 1,
        ?sc_gc_interval => 10,
        ?sc_grace_blocks => 10,
        ?sc_open_validation_bugfix => 1,
        ?sc_overcommit => 2,
        ?sc_version => 2,
        ?securities_percent => 0.34,
        ?snapshot_interval => 720,
        ?snapshot_version => 1,
        ?stake_withdrawal_cooldown => 250000,
        ?stake_withdrawal_max => 60,
        ?staking_fee_txn_add_gateway_v1 => 4000000,
        ?staking_fee_txn_assert_location_v1 => 1000000,
        ?staking_fee_txn_oui_v1 => 10000000,
        ?staking_fee_txn_oui_v1_per_address => 10000000,
        ?staking_keys =>
            <<33, 1, 37, 193, 104, 249, 129, 155, 16, 116, 103, 223, 160, 89, 196, 199, 11, 94, 109,
                49, 204, 84, 242, 3, 141, 250, 172, 153, 4, 226, 99, 215, 122, 202, 33, 1, 90, 111,
                210, 126, 196, 168, 67, 148, 63, 188, 231, 78, 255, 150, 151, 91, 237, 189, 148, 99,
                248, 41, 4, 103, 140, 225, 49, 117, 68, 212, 132, 113, 33, 1, 81, 215, 107, 13, 100,
                54, 92, 182, 84, 235, 120, 236, 201, 115, 77, 249, 2, 33, 68, 206, 129, 109, 248,
                58, 188, 53, 45, 34, 109, 251, 217, 130, 33, 1, 251, 174, 74, 242, 43, 25, 156, 188,
                167, 30, 41, 145, 14, 91, 0, 202, 115, 173, 26, 162, 174, 205, 45, 244, 46, 171,
                200, 191, 85, 222, 98, 120, 33, 1, 253, 88, 22, 88, 46, 94, 130, 1, 58, 115, 46,
                153, 194, 91, 1, 57, 194, 165, 181, 225, 251, 12, 13, 104, 171, 131, 151, 164, 83,
                113, 147, 216, 33, 1, 6, 76, 109, 192, 213, 45, 64, 27, 225, 251, 102, 247, 132, 42,
                154, 145, 70, 61, 127, 106, 188, 70, 87, 23, 13, 91, 43, 28, 70, 197, 41, 91, 33, 1,
                53, 200, 215, 84, 164, 84, 136, 102, 97, 157, 211, 75, 206, 229, 73, 177, 83, 153,
                199, 255, 43, 180, 114, 30, 253, 206, 245, 194, 79, 156, 218, 193, 33, 1, 229, 253,
                194, 42, 80, 229, 8, 183, 20, 35, 52, 137, 60, 18, 191, 28, 127, 218, 234, 118, 173,
                23, 91, 129, 251, 16, 39, 223, 252, 71, 165, 120, 33, 1, 54, 171, 198, 219, 118,
                150, 6, 150, 227, 80, 208, 92, 252, 28, 183, 217, 134, 4, 217, 2, 166, 9, 57, 106,
                38, 182, 158, 255, 19, 16, 239, 147, 33, 1, 51, 170, 177, 11, 57, 0, 18, 245, 73,
                13, 235, 147, 51, 37, 187, 248, 125, 197, 173, 25, 11, 36, 187, 66, 9, 240, 61, 104,
                28, 102, 194, 66, 33, 1, 187, 46, 236, 46, 25, 214, 204, 51, 20, 191, 86, 116, 0,
                174, 4, 247, 132, 145, 22, 83, 66, 159, 78, 13, 54, 52, 251, 8, 143, 59, 191, 196>>,
        ?transfer_hotspot_stale_poc_blocks => 1200,
        ?txn_fee_multiplier => 5000,
        ?txn_fees => true,
        ?validator_liveness_grace_period => 50,
        ?validator_liveness_interval => 100,
        ?validator_minimum_stake => 1000000000000,
        ?validator_version => 1,
        ?var_gw_inactivity_threshold => 600,
        ?vars_commit_delay => 1,
        ?witness_redundancy => 4,
        ?witness_refresh_interval => 200,
        ?witness_refresh_rand_n => 1000
    }.

gen_locations(Addresses) ->
    lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I / 50}, 13) | Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ).
