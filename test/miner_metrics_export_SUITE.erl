-module(miner_metrics_export_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

-export([
    all/0, test_cases/0, init_per_testcase/2, end_per_testcase/2
]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
-export([
    metrics_export_test/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------
all() ->
    [metrics_export_test].

test_cases() ->
    [metrics_export_test].

init_per_testcase(TestCase, Config) ->
    application:ensure_all_started(hackney),
    miner_ct_utils:init_per_testcase(?MODULE, TestCase, [{split_miners_vals_and_gateways, true},
                                                         {num_validators, 9},
                                                         {num_gateways, 6},
                                                         {num_consensus_members, 4},
                                                         {gateways_run_chain, false},
                                                         {export_metrics, [block_metrics, grpc_metrics]} | Config]).

end_per_testcase(TestCase, Config) ->
    gen_server:stop(miner_fake_radio_backplane),
    miner_ct_utils:end_per_testcase(TestCase, Config).
%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
metrics_export_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    setup_test(Config, maps:merge(CommonPOCVars, extra_vars())),

    NumVals = ?config(num_validators, Config),
    ScrapedMetrics = [scrape_metrics(19090 + P) || P <- lists:seq(1, NumVals + 1)],

    LineCounts = bucket_metrics(lists:flatten(ScrapedMetrics)),
    ct:pal("Metrics lines recorded ~p", [LineCounts]),

    Results = lists:all(fun(X) -> X > 0 end, maps:values(LineCounts)),
    ?assert(Results).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

setup_test(Config, VarMap) ->
    AllMiners = ?config(miners, Config),
    Validators = ?config(validators, Config),
    Gateways = ?config(gateways, Config),
    RunChainOnGateways = proplists:get_value(gateways_run_chain, Config, true),
    {_, Locations} = lists:unzip(initialize_chain(Validators, Config, VarMap)),

    case RunChainOnGateways of
        true ->
            _ = miner_ct_utils:integrate_genesis_block(hd(Validators), Gateways);
        false ->
            ok
    end,

    %% the radio ports used to be fetched from miner lora as part of init_per_testcase
    %% but the port is only opened now after a chain is up and been consulted to
    %% determine if validators are running POCs
    %% So now we have wait until the chain is up and miner lora has opened the port
    true = miner_ct_utils:wait_for_lora_port(Gateways, miner_lora_light, 30),

    RadioPorts = lists:map(
        fun(Gateway) ->
            {ok, RandomPort} = ct_rpc:call(Gateway, miner_lora_light, port, []),
            ct:pal("~p is listening for packet forwarder on ~p", [Gateway, RandomPort]),
            RandomPort
        end,
    Gateways),
    {ok, _FakeRadioPid} = miner_fake_radio_backplane:start_link(maps:get(?poc_version, VarMap), 45000,
                                                                lists:zip(RadioPorts, Locations), true),
    miner_fake_radio_backplane ! go,
    %% wait till height 2
    case RunChainOnGateways of
        true ->
            ok = miner_ct_utils:wait_for_gte(height, AllMiners, 2, all, 30);
        false ->
            ok = miner_ct_utils:wait_for_gte(height, Validators, 2, all, 30)
    end,
    ok.

scrape_metrics(Port) ->
    Url = "http://localhost:" ++ integer_to_list(Port) ++ "/metrics",
    {ok, 200, _RespHeaders, Body} = hackney:request(get, Url, [], <<>>, [with_body]),
    SplitBody = string:split(Body, "\n", all),

    lists:filter(fun(<<"# ", _Rest/binary>>) -> false;
                    (<<"blockchain_block_absorb", _Rest/binary>>) -> true;
                    (<<"blockchain_block_height", _Rest/binary>>) -> true;
                    (<<"grpcbox_session_count", _Rest/binary>>) -> true;
                    (<<"grpcbox_session_latency", _Rest/binary>>) -> true;
                    (_) -> false
                 end, SplitBody).

bucket_metrics(Lines) ->
    Results = #{blockchain_height => 0, blockchain_absorb => 0, grpc_count => 0, grpc_latency => 0},
    IncrementFun = fun(V) -> V + 1 end,
    lists:foldl(fun(<<"blockchain_block_absorb", _Rest/binary>>, Acc) ->
                        maps:update_with(blockchain_absorb, IncrementFun, Acc);
                   (<<"blockchain_block_height", _Rest/binary>>, Acc) ->
                        maps:update_with(blockchain_height, IncrementFun, Acc);
                   (<<"grpcbox_session_count", _Rest/binary>>, Acc) ->
                        maps:update_with(grpc_count, IncrementFun, Acc);
                   (<<"grpcbox_session_latency", _Rest/binary>>, Acc) ->
                        maps:update_with(grpc_latency, IncrementFun, Acc);
                   (_, Acc) -> Acc
                end,
                Results,
                Lines).

gen_locations(Addresses) ->
    Locs = lists:foldl(
             fun(I, Acc) ->
                     [h3:from_geo({37.780586, -122.469470 + I/100}, 13)|Acc]
             end,
             [],
             lists:seq(1, length(Addresses))
            ),
    {Locs, Locs}.

initialize_chain(_AllMiners, Config, VarMap) ->
    AllAddresses = ?config(addresses, Config),
    Validators = ?config(validators, Config),
    ValidatorAddrs = ?config(validator_addrs, Config),
    GatewayAddrs = ?config(gateway_addrs, Config),

    N = ?config(num_consensus_members, Config),
    Curve = ?config(dkg_curve, Config),
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, VarMap),
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- AllAddresses],
    AddValTxns = [blockchain_txn_gen_validator_v1:new(Addr, Addr, ?bones(10000)) || Addr <- ValidatorAddrs],

    {ActualLocations, ClaimedLocations} = gen_locations(GatewayAddrs),
    ct:pal("GatewayAddrs: ~p, ActualLocations: ~p, ClaimedLocations: ~p",[GatewayAddrs, ActualLocations, ClaimedLocations]),
    AddressesWithLocations = lists:zip(GatewayAddrs, ActualLocations),
    AddressesWithClaimedLocations = lists:zip(GatewayAddrs, ClaimedLocations),
    InitialGenGatewayTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions ++ AddValTxns ++ InitialGenGatewayTxns,
    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Validators, InitialTransactions, ValidatorAddrs, N, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Validators -- DKGCompletedNodes),
    AddressesWithClaimedLocations.

common_poc_vars(Config) ->
    N = ?config(num_consensus_members, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    %% Don't put the poc version here
    %% Add it to the map in the tests above
    #{
      ?batch_size => BatchSize,
      ?dkg_curve => Curve,
      ?election_version => 6, %% TODO validators
      ?num_consensus_members => N,
      ?poc_challenge_interval => 15,
      ?poc_target_hex_parent_res => 5,
      ?poc_v4_exclusion_cells => 10,
      ?poc_v4_parent_res => 11,
      ?poc_v4_prob_bad_rssi => 0.01,
      ?poc_v4_prob_count_wt => 0.3,
      ?poc_v4_prob_good_rssi => 1.0,
      ?poc_v4_prob_no_rssi => 0.5,
      ?poc_v4_prob_rssi_wt => 0.3,
      ?poc_v4_prob_time_wt => 0.3,
      ?poc_v4_target_challenge_age => 300,
      ?poc_v4_target_exclusion_cells => 6000,
      ?poc_v4_target_prob_edge_wt => 0.2,
      ?poc_v5_target_prob_randomness_wt => 0.0,
      ?poc_v4_target_prob_score_wt => 0.8,
      ?poc_v4_target_score_curve => 5}.

extra_vars() ->
    InitialVars = maps:merge(#{
                                ?block_time => 5000,
                                ?consensus_percent => 0.06,
                                ?data_aggregation_version => 2,
                                ?dc_percent => 0.325,
                                ?election_interval => 10,
                                ?poc_centrality_wt => 0.5,
                                ?poc_challengees_percent => 0.18,
                                ?poc_challengers_percent => 0.0095,
                                ?poc_good_bucket_high => -80,
                                ?poc_good_bucket_low => -132,
                                ?poc_max_hop_cells => 2000,
                                ?poc_v4_prob_count_wt => 0.0,
                                ?poc_v4_prob_rssi_wt => 0.0,
                                ?poc_v4_prob_time_wt => 0.0,
                                ?poc_v4_randomness_wt => 0.5,
                                ?poc_v4_target_prob_edge_wt => 0.0,
                                ?poc_v4_target_prob_score_wt => 0.0,
                                ?poc_v5_target_prob_randomness_wt => 1.0,
                                ?poc_version => 10,
                                ?poc_witnesses_percent => 0.0855,
                                ?securities_percent => 0.34
                              }, miner_poc_test_utils:poc_v11_vars()),
    GrpcVars = #{
                 ?hip17_interactivity_blocks => 20,
                 ?poc_activity_filter_enabled => true,
                 ?poc_challenge_rate => 1,
                 ?poc_challenger_type => validator,
                 ?poc_receipts_absorb_timeout => 2,
                 ?poc_targeting_version => 5,
                 ?poc_timeout => 4,
                 ?poc_validator_ct_scale => 0.8,
                 ?poc_validator_ephemeral_key_timeout => 50,
                 ?reward_version => 5,
                 ?rewards_txn_version => 2,
                 ?validator_hb_reactivation_limit => 100
    },
    maps:merge(InitialVars, GrpcVars).
