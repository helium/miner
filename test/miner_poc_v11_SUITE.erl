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

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, extra_vars()),
    InitialPayments = miner_ct_utils:gen_payments(Addresses),
    Locations = gen_locations(Addresses),
    InitialGws = miner_ct_utils:gen_gateways(Addresses, Locations),
    Txns = InitialVars ++ InitialPayments ++ InitialGws,
    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, Txns, Addresses,
                                                         NumConsensusMembers, Curve),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes),
                                                                 Miners -- DKGCompletedNodes),
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    [ {master_key, {Priv, Pub}},
      {consensus_miners, ConsensusMiners},
      {non_consensus_miners, NonConsensusMiners} | Config ].

extra_vars() ->
    ExistingPOCVars = existing_poc_vars(),
    POCV11Vars = miner_poc_test_utils:poc_v11_vars(),
    maps:merge(ExistingPOCVars, POCV11Vars).

existing_poc_vars() ->
    #{
        ?poc_good_bucket_low => -132,
        ?poc_good_bucket_high => -80,
        ?poc_v5_target_prob_randomness_wt => 1.0,
        ?poc_v4_target_prob_edge_wt => 0.0,
        ?poc_v4_target_prob_score_wt => 0.0,
        ?poc_v4_prob_rssi_wt => 0.0,
        ?poc_v4_prob_time_wt => 0.0,
        ?poc_v4_randomness_wt => 0.5,
        ?poc_v4_prob_count_wt => 0.0,
        ?poc_centrality_wt => 0.5,
        ?poc_max_hop_cells => 2000
    }.

gen_locations(Addresses) ->
    lists:foldl(
      fun(I, Acc) ->
              [h3:from_geo({37.780586, -122.469470 + I/50}, 13)|Acc]
      end,
      [],
      lists:seq(1, length(Addresses))
     ).
