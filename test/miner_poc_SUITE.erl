-module(miner_poc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([
    all/0
]).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    basic_test/1,
    basic_test_light_gateway/1,
    poc_dist_v1_test/1,
    poc_dist_v2_test/1,
    poc_dist_v4_test/1,
    poc_dist_v4_partitioned_test/1,
    poc_dist_v5_test/1,
    poc_dist_v5_partitioned_test/1,
    poc_dist_v5_partitioned_lying_test/1,
    poc_dist_v6_test/1,
    poc_dist_v6_partitioned_test/1,
    poc_dist_v6_partitioned_lying_test/1,
    poc_dist_v7_test/1,
    poc_dist_v7_partitioned_test/1,
    poc_dist_v7_partitioned_lying_test/1,
    poc_dist_v8_test/1,
    poc_dist_v8_partitioned_test/1,
    poc_dist_v8_partitioned_lying_test/1,
    no_status_v8_test/1,
    restart_test/1,
    poc_dist_v10_test/1,
    poc_dist_v10_partitioned_test/1,
    poc_dist_v10_partitioned_lying_test/1,
    poc_dist_v11_test/1,
    poc_dist_v11_cn_test/1,
    poc_dist_v11_partitioned_test/1,
    poc_dist_v11_partitioned_lying_test/1
]).

-define(SFLOCS, [631210968910285823, 631210968909003263, 631210968912894463, 631210968907949567]).
-define(NYLOCS, [631243922668565503, 631243922671147007, 631243922895615999, 631243922665907711]).
-define(AUSTINLOCS1, [631781084745290239, 631781089167934463, 631781054839691775, 631781050465723903]).
-define(AUSTINLOCS2, [631781452049762303, 631781453390764543, 631781452924144639, 631781452838965759]).
-define(LALOCS, [631236297173835263, 631236292179769855, 631236329165333503, 631236328049271807]).
-define(CNLOCS1, [
                 631649369216118271, %% spare-tortilla-raccoon
                 631649369235022335, %% kind-tangerine-octopus
                 631649369177018879, %% damp-hemp-pangolin
                 631649369175419391  %% fierce-lipstick-poodle
                 ]).

-define(CNLOCS2, [
                 631649369213830655, %% raspy-parchment-pike
                 631649369205533183, %% fresh-gingham-porpoise
                 631649369207629311, %% innocent-irish-pheasant
                 631649368709059071  %% glorious-eggshell-finch
                ]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
     basic_test,
     basic_test_light_gateway,
     %% poc_dist_v1_test,
     %% poc_dist_v2_test,
     %% poc_dist_v4_test,
     %% poc_dist_v4_partitioned_test,
     %% poc_dist_v5_test,
     %% poc_dist_v5_partitioned_test,
     %% poc_dist_v5_partitioned_lying_test,
     %% poc_dist_v6_test,
     %% poc_dist_v6_partitioned_test,
     %% poc_dist_v6_partitioned_lying_test,
     %poc_dist_v7_test,
     %poc_dist_v7_partitioned_test,
     %poc_dist_v7_partitioned_lying_test,
     poc_dist_v8_test,
     poc_dist_v8_partitioned_test,
     poc_dist_v8_partitioned_lying_test,
     poc_dist_v10_test,
     poc_dist_v10_partitioned_test,
     poc_dist_v10_partitioned_lying_test,
     poc_dist_v11_test,
     poc_dist_v11_cn_test,
     poc_dist_v11_partitioned_test,
     poc_dist_v11_partitioned_lying_test,
     %% uncomment when poc placement enforcement starts.
     %% no_status_v8_test,
     restart_test].

init_per_testcase(basic_test = TestCase, Config) ->
    miner_ct_utils:init_base_dir_config(?MODULE, TestCase, Config);
init_per_testcase(basic_test_light_gateway = TestCase, Config) ->
    miner_ct_utils:init_base_dir_config(?MODULE, TestCase, Config);
init_per_testcase(restart_test = TestCase, Config) ->
    miner_ct_utils:init_base_dir_config(?MODULE, TestCase, Config);
init_per_testcase(TestCase, Config0) ->
    miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0).

end_per_testcase(TestCase, Config) when TestCase == basic_test;
                                        TestCase == basic_test_light_gateway ->
    catch gen_statem:stop(miner_poc_statem),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            BaseDir = ?config(base_dir, Config),
            os:cmd("rm -rf "++ BaseDir),
            ok;
        _ ->
            %% leave results alone for analysis
            ok
    end;
end_per_testcase(restart_test, Config) ->
    catch gen_statem:stop(miner_poc_statem),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            BaseDir = ?config(base_dir, Config),
            os:cmd("rm -rf "++BaseDir),
            ok;
        _ ->
            %% leave results alone for analysis
            ok
    end;
end_per_testcase(TestCase, Config) ->
    gen_server:stop(miner_fake_radio_backplane),
    miner_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
poc_dist_v1_test(Config) ->
    ct:pal("Config ~p", [Config]),
    %% Dont think it matters if v1 takes all the other common vars
    %% Just don't set any poc_version here
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v1_test, Config, CommonPOCVars).

poc_dist_v2_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v2_test, Config, maps:put(?poc_version, 2, CommonPOCVars)).

poc_dist_v4_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v4_test, Config, maps:put(?poc_version, 4, CommonPOCVars)).

poc_dist_v4_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v4_partitioned_test, Config, maps:put(?poc_version, 4, CommonPOCVars)).

poc_dist_v5_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v5_test, Config, maps:put(?poc_version, 5, CommonPOCVars)).

poc_dist_v5_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v5_partitioned_test, Config, maps:put(?poc_version, 5, CommonPOCVars)).

poc_dist_v5_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v5_partitioned_lying_test, Config, maps:put(?poc_version, 5, CommonPOCVars)).

poc_dist_v6_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v6_test, Config, maps:put(?poc_version, 6, CommonPOCVars)).

poc_dist_v6_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v6_partitioned_test, Config, maps:put(?poc_version, 6, CommonPOCVars)).

poc_dist_v6_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v6_partitioned_lying_test, Config, maps:put(?poc_version, 6, CommonPOCVars)).

poc_dist_v7_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v7_test, Config, maps:put(?poc_version, 7, CommonPOCVars)).

poc_dist_v7_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v7_partitioned_test, Config, maps:put(?poc_version, 7, CommonPOCVars)).

poc_dist_v7_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    run_dist_with_params(poc_dist_v7_partitioned_lying_test, Config, maps:put(?poc_version, 7, CommonPOCVars)).

poc_dist_v8_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v8),
    run_dist_with_params(poc_dist_v8_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v8_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v8),
    run_dist_with_params(poc_dist_v8_partitioned_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v8_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v8),
    run_dist_with_params(poc_dist_v8_partitioned_lying_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

no_status_v8_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v8),
    run_dist_with_params(poc_dist_v8_test, Config, maps:merge(CommonPOCVars, ExtraVars), false).

poc_dist_v10_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v10),
    run_dist_with_params(poc_dist_v10_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v10_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v10),
    run_dist_with_params(poc_dist_v10_partitioned_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v10_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v10),
    run_dist_with_params(poc_dist_v10_partitioned_lying_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v11_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v11),
    run_dist_with_params(poc_dist_v11_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v11_cn_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v11),
    run_dist_with_params(poc_dist_v11_cn_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v11_partitioned_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v11),
    run_dist_with_params(poc_dist_v11_partitioned_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

poc_dist_v11_partitioned_lying_test(Config) ->
    CommonPOCVars = common_poc_vars(Config),
    ExtraVars = extra_vars(poc_v11),
    run_dist_with_params(poc_dist_v11_partitioned_lying_test, Config, maps:merge(CommonPOCVars, ExtraVars)).

basic_test(Config) ->
    BaseDir = ?config(base_dir, Config),

    {PrivKey, PubKey} = new_random_key(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, _Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),

    % Now add genesis
    % Generate fake blockchains (just the keys)
    RandomKeys = miner_ct_utils:generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    ConbaseTxns = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    ConbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    VarsKeys = libp2p_crypto:generate_keys(ecc_compact),
    VarsTx = miner_ct_utils:make_vars(VarsKeys, #{?poc_challenge_interval => 20}),

    Txs = ConbaseTxns ++ ConbaseDCTxns ++ [GenConsensusGroupTx] ++ VarsTx,
    GenesisBlock = blockchain_block_v1:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, {PrivKey, PubKey}},
        {{37.780959, -122.467496}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.78101, -122.465372}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781179, -122.463226}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781281, -122.461038}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781349, -122.458892}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781468, -122.456617}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781637, -122.4543}, miner_ct_utils:new_random_key(ecc_compact)}
    ],

    % Add a Gateway
    AddGatewayTxs = miner_ct_utils:build_gateways(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AddGatewayTxs),

    true = miner_ct_utils:wait_until(fun() -> {ok, 2} =:= blockchain:height(Chain) end),

    % Assert the Gateways location
    AssertLocaltionTxns = miner_ct_utils:build_asserts(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AssertLocaltionTxns),

    true = miner_ct_utils:wait_until(fun() -> {ok, 3} =:= blockchain:height(Chain) end),
    {ok, Statem} = miner_poc_statem:start_link(#{delay => 5}),

    ?assertEqual(requesting,  erlang:element(1, sys:get_state(Statem))),
    ?assertEqual(Chain, erlang:element(3, erlang:element(2, sys:get_state(Statem)))), % Blockchain is = to Chain
    ?assertEqual(requesting, erlang:element(6, erlang:element(2, sys:get_state(Statem)))), % State is requesting

    % Mock submit_txn to actually add the block
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, _) ->
        miner_ct_utils:add_block(Chain, ConsensusMembers, [Txn])
    end),
    meck:new(miner_onion, [passthrough]),
    meck:expect(miner_onion, dial_framed_stream, fun(_, _, _) ->
        {ok, self()}
    end),

    meck:new(miner_onion_handler, [passthrough]),
    meck:expect(miner_onion_handler, send, fun(Stream, _Onion) ->
        ?assertEqual(self(), Stream)
    end),

    meck:new(blockchain_txn_poc_receipts_v1, [passthrough]),
    meck:expect(blockchain_txn_poc_receipts_v1, is_valid, fun(_, _) -> ok end),

    ?assertEqual(30, erlang:element(15, erlang:element(2, sys:get_state(Statem)))),

    % Add some block to start process
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),

    % 3 previous blocks + 1 block to start process + 1 block with poc req txn
    true = miner_ct_utils:wait_until(fun() -> {ok, 5} =:= blockchain:height(Chain) end),

    % Moving threw targeting and challenging
    true = miner_ct_utils:wait_until(fun() ->
                                             case sys:get_state(Statem) of
                                                 {receiving, _} -> true;
                                                 _Other -> false
                                             end
                                     end),

    % Send 7 receipts and add blocks to pass timeout
    ?assertEqual(0, maps:size(erlang:element(11, erlang:element(2, sys:get_state(Statem))))),
    Challengees = erlang:element(9, erlang:element(2, sys:get_state(Statem))),
    ok = send_receipts(LatLongs, Challengees),
    timer:sleep(100),

    ?assertEqual(receiving, erlang:element(6, erlang:element(2, sys:get_state(Statem)))),
    ?assert(maps:size(erlang:element(11, erlang:element(2, sys:get_state(Statem)))) > 0), % Get reponses

    % Passing receiving_timeout
    lists:foreach(
        fun(_) ->
            ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 20)
    ),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem))),
    ?assertEqual(0, erlang:element(12, erlang:element(2, sys:get_state(Statem)))), % Get receiving_timeout
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),

    true = miner_ct_utils:wait_until(fun() ->
                                             case sys:get_state(Statem) of
                                                 {waiting, _} -> true;
                                                 {submitting, _} -> true;
                                                 {requesting, _} -> true;
                                                 {_Other, _} -> false
                                             end
                                     end),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(miner_onion)),
    meck:unload(miner_onion),
    ?assert(meck:validate(miner_onion_handler)),
    meck:unload(miner_onion_handler),
    ?assert(meck:validate(blockchain_txn_poc_receipts_v1)),
    meck:unload(blockchain_txn_poc_receipts_v1),

    ok = gen_statem:stop(Statem),
    ok.

basic_test_light_gateway(Config) ->
    %% same test as above but this time we change the local gateway from full mode to light mode
    %% this is done before we start the POC statem
    %% when the POC statem is started it should default to requesting
    %% and remain in requesting even after it has exceeded the poc interval
    %% light gateways will never move out of requesting state
    BaseDir = ?config(base_dir, Config),

    {PrivKey, PubKey} = new_random_key(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, _Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),

    % Now add genesis
    % Generate fake blockchains (just the keys)
    RandomKeys = miner_ct_utils:generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    ConbaseTxns = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    ConbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    VarsKeys = libp2p_crypto:generate_keys(ecc_compact),

    ExtraVars = #{?poc_challenge_interval => 20},
    ct:pal("extra vars: ~p", [ExtraVars]),
    VarsTx = miner_ct_utils:make_vars(VarsKeys, ExtraVars),

    Txs = ConbaseTxns ++ ConbaseDCTxns ++ [GenConsensusGroupTx] ++ VarsTx,
    GenesisBlock = blockchain_block_v1:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, {PrivKey, PubKey}},
        {{37.780959, -122.467496}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.78101, -122.465372}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781179, -122.463226}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781281, -122.461038}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781349, -122.458892}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781468, -122.456617}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781637, -122.4543}, miner_ct_utils:new_random_key(ecc_compact)}
    ],

    % Add a Gateway
    AddGatewayTxs = miner_ct_utils:build_gateways(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AddGatewayTxs),

    true = miner_ct_utils:wait_until(fun() -> {ok, 2} =:= blockchain:height(Chain) end),

    % Assert the Gateways location
    AssertLocaltionTxns = miner_ct_utils:build_asserts(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AssertLocaltionTxns),

    true = miner_ct_utils:wait_until(fun() -> {ok, 3} =:= blockchain:height(Chain) end),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    %% update the local gateway to light mode
    %% we do this before we start the poc statem
    %% thereafter it should never move out of requesting state
    Ledger1 = blockchain_ledger_v1:new_context(Ledger),
    {ok, GWInfo} = blockchain_gateway_cache:get(Address, Ledger1),
    GWInfo2 = blockchain_ledger_gateway_v2:mode(light, GWInfo),
    blockchain_ledger_v1:update_gateway(GWInfo2, Address, Ledger1),
    ok = blockchain_ledger_v1:commit_context(Ledger1),

    {ok, Statem} = miner_poc_statem:start_link(#{delay => 5}),

    %% assert default states
    ct:pal("got state ~p", [sys:get_state(Statem)]),
    ?assertEqual(requesting, erlang:element(1, sys:get_state(Statem))),
    ?assertEqual(requesting, erlang:element(6, erlang:element(2, sys:get_state(Statem)))), % State is requesting

    % Mock submit_txn to  add blocks
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, _) ->
        miner_ct_utils:add_block(Chain, ConsensusMembers, [Txn])
    end),

    % Add some block to start process
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),

    % 3 previous blocks + 1 block to start process ( no POC req txn will have been submitted by the statem )
    true = miner_ct_utils:wait_until(fun() -> ct:pal("height: ~p", [blockchain:height(Chain)]), {ok, 4} =:= blockchain:height(Chain) end),

    % confirm we DO NOT move from receiving state
    true = miner_ct_utils:wait_until(fun() ->
                                             case sys:get_state(Statem) of
                                                 {requesting, _} -> true;
                                                 _Other -> ct:pal("got other state ~p", [_Other]), false
                                             end
                                     end),
    ?assertEqual(requesting, erlang:element(6, erlang:element(2, sys:get_state(Statem)))),

    % Passing poc interval
    lists:foreach(
        fun(_) ->
            ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 25)
    ),
    % confirm we remain in requesting state
    ?assertEqual(requesting,  erlang:element(1, sys:get_state(Statem))),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ok = gen_statem:stop(Statem),
    ok.

restart_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    {PrivKey, PubKey} = new_random_key(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, _Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),

    % Now add genesis
    % Generate fake blockchains (just the keys)
    RandomKeys = miner_ct_utils:generate_keys(6),
    Address = blockchain_swarm:pubkey_bin(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    ConbaseTxns = [blockchain_txn_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    ConbaseDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new([Addr || {Addr, _} <- ConsensusMembers], <<>>, 1, 0),
    VarsKeys = libp2p_crypto:generate_keys(ecc_compact),
    VarsTx = miner_ct_utils:make_vars(VarsKeys, #{?poc_challenge_interval => 20}),

    Txs = ConbaseTxns ++ ConbaseDCTxns ++ [GenConsensusGroupTx] ++ VarsTx,
    GenesisBlock = blockchain_block_v1:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    Chain = blockchain_worker:blockchain(),
    {ok, HeadBlock} = blockchain:head_block(Chain),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_block:hash_block(HeadBlock)),
    ?assertEqual({ok, GenesisBlock}, blockchain:head_block(Chain)),
    ?assertEqual({ok, blockchain_block:hash_block(GenesisBlock)}, blockchain:genesis_hash(Chain)),
    ?assertEqual({ok, GenesisBlock}, blockchain:genesis_block(Chain)),
    ?assertEqual({ok, 1}, blockchain:height(Chain)),

    % All these point are in a line one after the other (except last)
    LatLongs = [
        {{37.780586, -122.469471}, {PrivKey, PubKey}},
        {{37.780959, -122.467496}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.78101, -122.465372}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781179, -122.463226}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781281, -122.461038}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781349, -122.458892}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781468, -122.456617}, miner_ct_utils:new_random_key(ecc_compact)},
        {{37.781637, -122.4543}, miner_ct_utils:new_random_key(ecc_compact)}
    ],

    % Add a Gateway
    AddGatewayTxs = miner_ct_utils:build_gateways(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AddGatewayTxs),

    true = miner_ct_utils:wait_until(fun() -> {ok, 2} =:= blockchain:height(Chain) end),

    % Assert the Gateways location
    AssertLocaltionTxns = miner_ct_utils:build_asserts(LatLongs, {PrivKey, PubKey}),
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, AssertLocaltionTxns),

    true = miner_ct_utils:wait_until(fun() -> {ok, 3} =:= blockchain:height(Chain) end),

    {ok, Statem0} = miner_poc_statem:start_link(#{delay => 5,
                                                  base_dir => BaseDir}),

    ?assertEqual(requesting,  erlang:element(1, sys:get_state(Statem0))),
    ?assertEqual(Chain, erlang:element(3, erlang:element(2, sys:get_state(Statem0)))), % Blockchain is = to Chain
    ?assertEqual(requesting, erlang:element(6, erlang:element(2, sys:get_state(Statem0)))), % State is requesting

    % Mock submit_txn to actually add the block
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, submit_txn, fun(Txn, _) ->
        miner_ct_utils:add_block(Chain, ConsensusMembers, [Txn])
    end),
    meck:new(miner_onion, [passthrough]),
    meck:expect(miner_onion, dial_framed_stream, fun(_, _, _) ->
        {ok, self()}
    end),

    meck:new(miner_onion_handler, [passthrough]),
    meck:expect(miner_onion_handler, send, fun(Stream, _Onion) ->
        ?assertEqual(self(), Stream)
    end),

    meck:new(blockchain_txn_poc_receipts_v1, [passthrough]),
    meck:expect(blockchain_txn_poc_receipts_v1, is_valid, fun(_, _) -> ok end),

    ?assertEqual(30, erlang:element(15, erlang:element(2, sys:get_state(Statem0)))),

    % Add some block to start process
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),

    % 3 previous blocks + 1 block to start process + 1 block with poc req txn
    true = miner_ct_utils:wait_until(fun() -> {ok, 5} =:= blockchain:height(Chain) end),

    %% Moving through targeting and challenging
    true = miner_ct_utils:wait_until(
           fun() ->
                   case sys:get_state(Statem0) of
                       {receiving, _} -> true;
                       _Other ->
                           ct:pal("other state ~p", [_Other]),
                           false
                   end
           end),

    % KILLING STATEM AND RESTARTING
    ok = gen_statem:stop(Statem0),
    {ok, Statem1} = miner_poc_statem:start_link(#{delay => 5,
                                                  base_dir => BaseDir}),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem1))),
    ?assertEqual(receiving, erlang:element(6, erlang:element(2, sys:get_state(Statem1)))),

    % Send 7 receipts and add blocks to pass timeout
    ?assertEqual(0, maps:size(erlang:element(11, erlang:element(2, sys:get_state(Statem1))))),
    Challengees = erlang:element(9, erlang:element(2, sys:get_state(Statem1))),
    ok = send_receipts(LatLongs, Challengees),
    timer:sleep(100),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem1))),
    ?assertEqual(receiving, erlang:element(6, erlang:element(2, sys:get_state(Statem1)))),
    ?assert(maps:size(erlang:element(11, erlang:element(2, sys:get_state(Statem1)))) > 0), % Get reponses

    % Passing receiving_timeout
    lists:foreach(
        fun(_) ->
            ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 10)
    ),

    ?assertEqual(receiving,  erlang:element(1, sys:get_state(Statem1))),
    ?assertEqual(0, erlang:element(12, erlang:element(2, sys:get_state(Statem1)))), % Get receiving_timeout
    ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),

    true = miner_ct_utils:wait_until(
           fun() ->
                   case sys:get_state(Statem1) of
                       {waiting, _} -> true;
                       {submitting, _} -> true;
                       {requesting, _} -> true;
                       {_Other, _} ->
                           ct:pal("other state ~p", [_Other]),
                           false
                   end
           end),

    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(miner_onion)),
    meck:unload(miner_onion),
    ?assert(meck:validate(miner_onion_handler)),
    meck:unload(miner_onion_handler),
    ?assert(meck:validate(blockchain_txn_poc_receipts_v1)),
    meck:unload(blockchain_txn_poc_receipts_v1),

    ok = gen_statem:stop(Statem1),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
send_receipts(LatLongs, Challengees) ->
    lists:foreach(
        fun({_LatLong, {PrivKey, PubKey}}) ->
            Address = libp2p_crypto:pubkey_to_bin(PubKey),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            {Mega, Sec, Micro} = os:timestamp(),
            Timestamp = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
            case lists:keyfind(Address, 1, Challengees) of
                {Address, LayerData} ->
                    Receipt = blockchain_poc_receipt_v1:new(Address, Timestamp, 0, LayerData, radio),
                    SignedReceipt = blockchain_poc_receipt_v1:sign(Receipt, SigFun),
                    miner_poc_statem:receipt(make_ref(), SignedReceipt, "/ip4/127.0.0.1/tcp/1234");
                _ ->
                    ok
            end
        end,
        LatLongs
    ).

new_random_key(Curve) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(Curve),
    {PrivKey, PubKey}.

run_dist_with_params(TestCase, Config, VarMap) ->
    run_dist_with_params(TestCase, Config, VarMap, true).

run_dist_with_params(TestCase, Config, VarMap, Status) ->
    ok = setup_dist_test(TestCase, Config, VarMap, Status),
    %% Execute the test
    ok = exec_dist_test(TestCase, Config, VarMap, Status),
    %% show the final receipt counter
    Miners = ?config(miners, Config),
    FinalReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    ct:pal("FinalReceiptMap: ~p", [FinalReceiptMap]),
    ct:pal("FinalReceiptCounter: ~p", [receipt_counter(FinalReceiptMap)]),
    %% The test endeth here
    ok.

exec_dist_test(poc_dist_v11_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v11_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v10_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v10_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v8_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v8_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v7_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v7_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v6_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v6_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v5_partitioned_lying_test, Config, VarMap, _Status) ->
    do_common_partition_lying_checks(poc_dist_v5_partitioned_lying_test, Config, VarMap);
exec_dist_test(poc_dist_v11_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v11_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v10_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v10_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v8_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v8_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v7_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v7_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v6_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v6_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v5_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v5_partitioned_test, Config, VarMap);
exec_dist_test(poc_dist_v4_partitioned_test, Config, VarMap, _Status) ->
    do_common_partition_checks(poc_dist_v4_partitioned_test, Config, VarMap);
exec_dist_test(TestCase, Config, VarMap, Status) ->
    Miners = ?config(miners, Config),
    %% Print scores before we begin the test
    InitialScores = gateway_scores(Config),
    ct:pal("InitialScores: ~p", [InitialScores]),
    %% check that every miner has issued a challenge
    case Status of
        %% expect failure and exit
        false ->
            ?assertEqual(false, check_all_miners_can_challenge(Miners));
        true ->
            ?assert(check_all_miners_can_challenge(Miners)),
            %% Check that the receipts are growing ONLY for poc_v4
            %% More specifically, first receipt can have a single element path (beacon)
            %% but subsequent ones must have more than one element in the path, reason being
            %% the first receipt would have added witnesses and we should be able to make
            %% a next hop.
            case maps:get(?poc_version, VarMap, 1) of
                V when V >= 10 ->
                    %% There are no paths in v11 or v10 for that matter, so we'll consolidate
                    %% the checks for both poc-v10 and poc-v11 here
                    true = miner_ct_utils:wait_until(
                             fun() ->
                                     %% Check that we have atleast more than one request
                                     %% If we have only one request, there's no guarantee
                                     %% that the paths would eventually grow
                                     C1 = check_multiple_requests(Miners),
                                     %% Check if we have some receipts
                                     C2 = maps:size(challenger_receipts_map(find_receipts(Miners))) > 0,
                                     %% Check there are some poc rewards
                                     RewardsMD = get_rewards_md(Config),
                                     ct:pal("RewardsMD: ~p", [RewardsMD]),
                                     C3 = check_non_empty_poc_rewards(take_poc_challengee_and_witness_rewards(RewardsMD)),
                                     ct:pal("C1: ~p, C2: ~p, C3: ~p", [C1, C2, C3]),
                                     C1 andalso C2 andalso C3
                             end,
                             300, 1000),
                    FinalRewards = get_rewards(Config),
                    ct:pal("FinalRewards: ~p", [FinalRewards]),
                    ok;
                V when V > 3 ->
                    true = miner_ct_utils:wait_until(
                             fun() ->
                                     %% Check that we have atleast more than one request
                                     %% If we have only one request, there's no guarantee
                                     %% that the paths would eventually grow
                                     C1 = check_multiple_requests(Miners),
                                     %% Now we can check whether we have path growth
                                     C2 = (check_eventual_path_growth(TestCase, Miners) orelse
                                           check_subsequent_path_growth(challenger_receipts_map(find_receipts(Miners)))),
                                     %% Check there are some poc rewards
                                     C3 = check_poc_rewards(get_rewards(Config)),
                                     ct:pal("C1: ~p, C2: ~p, C3: ~p", [C1, C2, C3]),
                                     C1 andalso C2 andalso C3
                             end,
                             120, 1000),
                    FinalScores = gateway_scores(Config),
                    ct:pal("FinalScores: ~p", [FinalScores]),
                    FinalRewards = get_rewards(Config),
                    ct:pal("FinalRewards: ~p", [FinalRewards]),
                    ok;
                _ ->
                    %% By this point, we have ensured that every miner
                    %% has a valid request atleast once, we just check
                    %% that we have N (length(Miners)) receipts.
                    ?assert(check_atleast_k_receipts(Miners, length(Miners))),
                    ok
            end
    end,
    ok.

setup_dist_test(TestCase, Config, VarMap, Status) ->
    Miners = ?config(miners, Config),
    MinersAndPorts = ?config(ports, Config),
    {_, Locations} = lists:unzip(initialize_chain(Miners, TestCase, Config, VarMap)),
    GenesisBlock = miner_ct_utils:get_genesis_block(Miners, Config),
    RadioPorts = [ P || {_Miner, {_TP, P, _JRPCP}} <- MinersAndPorts ],
    {ok, _FakeRadioPid} = miner_fake_radio_backplane:start_link(maps:get(?poc_version, VarMap), 45000,
                                                                lists:zip(RadioPorts, Locations), Status),
    ok = miner_ct_utils:load_genesis_block(GenesisBlock, Miners, Config),
    miner_fake_radio_backplane ! go,
    %% wait till height 10
    ok = miner_ct_utils:wait_for_gte(height, Miners, 10, all, 30),
    ok.

gen_locations(poc_dist_v11_partitioned_lying_test, _, _) ->
    {?AUSTINLOCS1 ++ ?LALOCS, lists:duplicate(4, hd(?AUSTINLOCS1)) ++ lists:duplicate(4, hd(?LALOCS))};
gen_locations(poc_dist_v10_partitioned_lying_test, _, _) ->
    {?AUSTINLOCS1 ++ ?LALOCS, lists:duplicate(4, hd(?AUSTINLOCS1)) ++ lists:duplicate(4, hd(?LALOCS))};
gen_locations(poc_dist_v8_partitioned_lying_test, _, _) ->
    {?AUSTINLOCS1 ++ ?LALOCS, lists:duplicate(4, hd(?AUSTINLOCS1)) ++ lists:duplicate(4, hd(?LALOCS))};
gen_locations(poc_dist_v7_partitioned_lying_test, _, _) ->
    {?SFLOCS ++ ?NYLOCS, lists:duplicate(4, hd(?SFLOCS)) ++ lists:duplicate(4, hd(?NYLOCS))};
gen_locations(poc_dist_v6_partitioned_lying_test, _, _) ->
    {?SFLOCS ++ ?NYLOCS, lists:duplicate(4, hd(?SFLOCS)) ++ lists:duplicate(4, hd(?NYLOCS))};
gen_locations(poc_dist_v5_partitioned_lying_test, _, _) ->
    {?SFLOCS ++ ?NYLOCS, lists:duplicate(4, hd(?SFLOCS)) ++ lists:duplicate(4, hd(?NYLOCS))};
gen_locations(poc_dist_v11_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?AUSTINLOCS1 ++ ?LALOCS, ?AUSTINLOCS1 ++ ?LALOCS};
gen_locations(poc_dist_v10_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?AUSTINLOCS1 ++ ?LALOCS, ?AUSTINLOCS1 ++ ?LALOCS};
gen_locations(poc_dist_v8_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?AUSTINLOCS1 ++ ?LALOCS, ?AUSTINLOCS1 ++ ?LALOCS};
gen_locations(poc_dist_v7_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?SFLOCS ++ ?NYLOCS, ?SFLOCS ++ ?NYLOCS};
gen_locations(poc_dist_v6_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?SFLOCS ++ ?NYLOCS, ?SFLOCS ++ ?NYLOCS};
gen_locations(poc_dist_v5_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?SFLOCS ++ ?NYLOCS, ?SFLOCS ++ ?NYLOCS};
gen_locations(poc_dist_v4_partitioned_test, _, _) ->
    %% These are taken from the ledger
    {?SFLOCS ++ ?NYLOCS, ?SFLOCS ++ ?NYLOCS};
gen_locations(poc_dist_v8_test, _, _) ->
    %% Actual locations are the same as the claimed locations for the dist test
    {?AUSTINLOCS1 ++ ?AUSTINLOCS2, ?AUSTINLOCS1 ++ ?AUSTINLOCS2};
gen_locations(poc_dist_v11_cn_test, _, _) ->
    %% Actual locations are the same as the claimed locations for the dist test
    {?CNLOCS1 ++ ?CNLOCS2, ?CNLOCS1 ++ ?CNLOCS2};
gen_locations(poc_dist_v11_test, _, _) ->
    %% Actual locations are the same as the claimed locations for the dist test
    {?AUSTINLOCS1 ++ ?AUSTINLOCS2, ?AUSTINLOCS1 ++ ?AUSTINLOCS2};
gen_locations(poc_dist_v10_test, _, _) ->
    %% Actual locations are the same as the claimed locations for the dist test
    {?AUSTINLOCS1 ++ ?AUSTINLOCS2, ?AUSTINLOCS1 ++ ?AUSTINLOCS2};
gen_locations(_TestCase, Addresses, VarMap) ->
    LocationJitter = case maps:get(?poc_version, VarMap, 1) of
                         V when V > 3 ->
                             100;
                         _ ->
                             1000000
                     end,

    Locs = lists:foldl(
             fun(I, Acc) ->
                     [h3:from_geo({37.780586, -122.469470 + I/LocationJitter}, 13)|Acc]
             end,
             [],
             lists:seq(1, length(Addresses))
            ),
    {Locs, Locs}.

initialize_chain(Miners, TestCase, Config, VarMap) ->
    Addresses = ?config(addresses, Config),
    N = ?config(num_consensus_members, Config),
    Curve = ?config(dkg_curve, Config),
    Keys = libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, VarMap),
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    {ActualLocations, ClaimedLocations} = gen_locations(TestCase, Addresses, VarMap),
    AddressesWithLocations = lists:zip(Addresses, ActualLocations),
    AddressesWithClaimedLocations = lists:zip(Addresses, ClaimedLocations),
    InitialGenGatewayTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions ++ InitialGenGatewayTxns,
    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialTransactions, Addresses, N, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),


    AddressesWithClaimedLocations.

find_requests(Miners) ->
    [M | _] = Miners,
    Chain = ct_rpc:call(M, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(M, blockchain, blocks, [Chain]),
    lists:flatten(lists:foldl(fun({_Hash, Block}, Acc) ->
                                      Txns = blockchain_block:transactions(Block),
                                      Requests = lists:filter(fun(T) ->
                                                                      blockchain_txn:type(T) == blockchain_txn_poc_request_v1
                                                              end,
                                                              Txns),
                                      [Requests | Acc]
                              end,
                              [],
                              maps:to_list(Blocks))).

find_receipts(Miners) ->
    [M | _] = Miners,
    Chain = ct_rpc:call(M, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(M, blockchain, blocks, [Chain]),
    lists:flatten(lists:foldl(fun({_Hash, Block}, Acc) ->
                                      Txns = blockchain_block:transactions(Block),
                                      Height = blockchain_block:height(Block),
                                      Receipts = lists:filter(fun(T) ->
                                                                      blockchain_txn:type(T) == blockchain_txn_poc_receipts_v1
                                                              end,
                                                              Txns),
                                      TaggedReceipts = lists:map(fun(R) ->
                                                                         {Height, R}
                                                                 end,
                                                                 Receipts),
                                      TaggedReceipts ++ Acc
                              end,
                              [],
                              maps:to_list(Blocks))).

challenger_receipts_map(Receipts) ->
    ReceiptMap = lists:foldl(
                   fun({_Height, Receipt}=R, Acc) ->
                           {ok, Challenger} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_txn_poc_receipts_v1:challenger(Receipt))),
                           case maps:get(Challenger, Acc, undefined) of
                               undefined ->
                                   maps:put(Challenger, [R], Acc);
                               List ->
                                   maps:put(Challenger, lists:keysort(1, [R | List]), Acc)
                           end
                   end,
                   #{},
                   Receipts),

    ct:pal("ReceiptMap: ~p", [ReceiptMap]),

    ReceiptMap.

request_counter(TotalRequests) ->
    lists:foldl(fun(Req, Acc) ->
                        {ok, Challenger} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_txn_poc_request_v1:challenger(Req))),
                        case maps:get(Challenger, Acc, undefined) of
                            undefined ->
                                maps:put(Challenger, 1, Acc);
                            N when N > 0 ->
                                maps:put(Challenger, N + 1, Acc);
                            _ ->
                                maps:put(Challenger, 1, Acc)
                        end
                end,
                #{},
                TotalRequests).


check_all_miners_can_challenge(Miners) ->
    N = length(Miners),
    RequestCounter = request_counter(find_requests(Miners)),
    ct:pal("RequestCounter: ~p~n", [RequestCounter]),

    N == maps:size(RequestCounter).

check_eventual_path_growth(TestCase, Miners) ->
    ReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    ct:pal("ReceiptMap: ~p", [ReceiptMap]),
    check_growing_paths(TestCase, ReceiptMap, active_gateways(Miners), false).

check_partitioned_path_growth(_TestCase, Miners) ->
    ReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    ct:pal("ReceiptMap: ~p", [ReceiptMap]),
    check_subsequent_path_growth(ReceiptMap).

check_partitioned_lying_path_growth(_TestCase, Miners) ->
    ReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    ct:pal("ReceiptMap: ~p", [ReceiptMap]),
    not check_subsequent_path_growth(ReceiptMap).

check_growing_paths(TestCase, ReceiptMap, ActiveGateways, PartitionFlag) ->
    Results = lists:foldl(fun({_Challenger, TaggedReceipts}, Acc) ->
                                  [{_, FirstReceipt} | Rest] = TaggedReceipts,
                                  %% It's possible that the first receipt itself has multiple elements path, I think
                                  RemainingGrowthCond = case PartitionFlag of
                                                            true ->
                                                                check_remaining_partitioned_grow(TestCase, Rest, ActiveGateways);
                                                            false ->
                                                                check_remaining_grow(Rest)
                                                        end,
                                  Res = length(blockchain_txn_poc_receipts_v1:path(FirstReceipt)) >= 1 andalso RemainingGrowthCond,
                                  [Res | Acc]
                          end,
                          [],
                          maps:to_list(ReceiptMap)),
    lists:all(fun(R) -> R == true end, Results) andalso maps:size(ReceiptMap) == maps:size(ActiveGateways).

check_remaining_grow([]) ->
    false;
check_remaining_grow(TaggedReceipts) ->
    Res = lists:map(fun({_, Receipt}) ->
                            length(blockchain_txn_poc_receipts_v1:path(Receipt)) > 1
                    end,
                    TaggedReceipts),
    %% It's possible that even some of the remaining receipts have single path
    %% but there should eventually be some which have multi element paths
    lists:any(fun(R) -> R == true end, Res).

check_remaining_partitioned_grow(_TestCase, [], _ActiveGateways) ->
    false;
check_remaining_partitioned_grow(TestCase, TaggedReceipts, ActiveGateways) ->
    Res = lists:map(fun({_, Receipt}) ->
                            Path = blockchain_txn_poc_receipts_v1:path(Receipt),
                            PathLength = length(Path),
                            ct:pal("PathLength: ~p", [PathLength]),
                            PathLength > 1 andalso PathLength =< 4 andalso check_partitions(TestCase, Path, ActiveGateways)
                    end,
                    TaggedReceipts),
    ct:pal("Res: ~p", [Res]),
    %% It's possible that even some of the remaining receipts have single path
    %% but there should eventually be some which have multi element paths
    lists:any(fun(R) -> R == true end, Res).

check_partitions(TestCase, Path, ActiveGateways) ->
    PathLocs = sets:from_list(lists:foldl(fun(Element, Acc) ->
                                                  Challengee = blockchain_poc_path_element_v1:challengee(Element),
                                                  ChallengeeGw = maps:get(Challengee, ActiveGateways),
                                                  ChallengeeLoc = blockchain_ledger_gateway_v2:location(ChallengeeGw),
                                                  [ChallengeeLoc | Acc]
                                          end,
                                          [],
                                          Path)),
    {LocSet1, LocSet2} = location_sets(TestCase),
    case sets:is_subset(PathLocs, LocSet1) of
        true ->
            %% Path is in LocSet1, check that it's not in LocSet2
            sets:is_disjoint(PathLocs, LocSet2);
        false ->
            %% Path is not in LocSet1, check that it's only in LocSet2
            sets:is_subset(PathLocs, LocSet2) andalso sets:is_disjoint(PathLocs, LocSet1)
    end.

check_multiple_requests(Miners) ->
    RequestCounter = request_counter(find_requests(Miners)),
    ct:pal("RequestCounter: ~p", [RequestCounter]),
    lists:sum(maps:values(RequestCounter)) > length(Miners).

check_atleast_k_receipts(Miners, K) ->
    ReceiptMap = challenger_receipts_map(find_receipts(Miners)),
    TotalReceipts = lists:foldl(fun(ReceiptList, Acc) ->
                                        length(ReceiptList) + Acc
                                end,
                                0,
                                maps:values(ReceiptMap)),
    ct:pal("TotalReceipts: ~p", [TotalReceipts]),
    TotalReceipts >= K.

receipt_counter(ReceiptMap) ->
    lists:foldl(fun({Name, ReceiptList}, Acc) ->
                        Counts = lists:map(fun({Height, ReceiptTxn}) ->
                                                   {Height, length(blockchain_txn_poc_receipts_v1:path(ReceiptTxn))}
                                           end,
                                           ReceiptList),
                        maps:put(Name, Counts, Acc)
                end,
                #{},
                maps:to_list(ReceiptMap)).

active_gateways([Miner | _]=_Miners) ->
    %% Get active gateways to get the locations
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    ct_rpc:call(Miner, blockchain_ledger_v1, active_gateways, [Ledger]).

gateway_scores(Config) ->
    [Miner | _] = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    lists:foldl(fun(Address, Acc) ->
                        {ok, S} = ct_rpc:call(Miner, blockchain_ledger_v1, gateway_score, [Address, Ledger]),
                        {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(Address)),
                        maps:put(Name, S, Acc)
                end,
                #{},
                Addresses).

common_poc_vars(Config) ->
    N = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    Interval = ?config(election_interval, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    %% Don't put the poc version here
    %% Add it to the map in the tests above
    #{?block_time => BlockTime,
      ?election_interval => Interval,
      ?num_consensus_members => N,
      ?batch_size => BatchSize,
      ?dkg_curve => Curve,
      ?election_version => 4, %% TODO validators
      ?poc_challenge_interval => 15,
      ?poc_v4_exclusion_cells => 10,
      ?poc_v4_parent_res => 11,
      ?poc_v4_prob_bad_rssi => 0.01,
      ?poc_v4_prob_count_wt => 0.3,
      ?poc_v4_prob_good_rssi => 1.0,
      ?poc_v4_prob_no_rssi => 0.5,
      ?poc_v4_prob_rssi_wt => 0.3,
      ?poc_v4_prob_time_wt => 0.3,
      ?poc_v4_randomness_wt => 0.1,
      ?poc_v4_target_challenge_age => 300,
      ?poc_v4_target_exclusion_cells => 6000,
      ?poc_v4_target_prob_edge_wt => 0.2,
      ?poc_v4_target_prob_score_wt => 0.8,
      ?poc_v4_target_score_curve => 5,
      ?poc_target_hex_parent_res => 5,
      ?poc_v5_target_prob_randomness_wt => 0.0}.

do_common_partition_checks(TestCase, Config, VarMap) ->
    Miners = ?config(miners, Config),
    %% Print scores before we begin the test
    InitialScores = gateway_scores(Config),
    ct:pal("InitialScores: ~p", [InitialScores]),
    true = miner_ct_utils:wait_until(
             fun() ->
                     case maps:get(poc_version, VarMap, 1) of
                         V when V >= 10 ->
                             %% There is no path to check, so do both poc-v10 and poc-v11 checks here
                             %% Check that every miner has issued a challenge
                             C1 = check_all_miners_can_challenge(Miners),
                             %% Check that we have atleast more than one request
                             %% If we have only one request, there's no guarantee
                             %% that the paths would eventually grow
                             C2 = check_multiple_requests(Miners),
                             %% Check there are some poc rewards
                             RewardsMD = get_rewards_md(Config),
                             ct:pal("RewardsMD: ~p", [RewardsMD]),
                             C3 = check_non_empty_poc_rewards(take_poc_challengee_and_witness_rewards(RewardsMD)),
                             ct:pal("C1: ~p, C2: ~p, C3: ~p", [C1, C2, C3]),
                             C1 andalso C2 andalso C3;
                         _ ->
                             %% Check that every miner has issued a challenge
                             C1 = check_all_miners_can_challenge(Miners),
                             %% Check that we have atleast more than one request
                             %% If we have only one request, there's no guarantee
                             %% that the paths would eventually grow
                             C2 = check_multiple_requests(Miners),
                             %% Since we have two static location partitioned networks, we
                             %% can assert that the subsequent path lengths must never be greater
                             %% than 4.
                             C3 = check_partitioned_path_growth(TestCase, Miners),
                             %% Check there are some poc rewards
                             C4 = check_poc_rewards(get_rewards(Config)),
                             ct:pal("all can challenge: ~p, multiple requests: ~p, paths grow: ~p, rewards given: ~p", [C1, C2, C3, C4]),
                             C1 andalso C2 andalso C3 andalso C4
                     end
             end, 60, 5000),
    %% Print scores after execution
    FinalScores = gateway_scores(Config),
    ct:pal("FinalScores: ~p", [FinalScores]),
    FinalRewards = get_rewards(Config),
    ct:pal("FinalRewards: ~p", [FinalRewards]),
    ok.

balances(Config) ->
    [Miner | _] = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    [miner_ct_utils:get_balance(Miner, Addr) || Addr <- Addresses].

take_poc_challengee_and_witness_rewards(RewardsMD) ->
    %% only take poc_challengee and poc_witness rewards
    POCRewards = lists:foldl(
                   fun({Ht, MDMap}, Acc) ->
                           [{Ht, maps:with([poc_challengee, poc_witness], MDMap)} | Acc]
                   end,
                   [],
                   RewardsMD),
    ct:pal("POCRewards: ~p", [POCRewards]),
    POCRewards.

check_non_empty_poc_rewards(POCRewards) ->
    lists:any(
      fun({_Ht, #{poc_challengee := R1, poc_witness := R2}}) ->
              maps:size(R1) > 0 andalso maps:size(R2) > 0
      end,
      POCRewards).


get_rewards_md(Config) ->
    %% NOTE: It's possible that the calculations below may blow up
    %% since we are folding the entire chain here and some subsequent
    %% ledger_at call in rewards_metadata blows up. Investigate

    [Miner | _] = ?config(miners, Config),
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    {ok, Head} = ct_rpc:call(Miner, blockchain, head_block, [Chain]),

    Filter = fun(T) -> blockchain_txn:type(T) == blockchain_txn_rewards_v2 end,
    Fun = fun(Block, Acc) ->
        case blockchain_utils:find_txn(Block, Filter) of
            [T] ->
                Start = blockchain_txn_rewards_v2:start_epoch(T),
                End = blockchain_txn_rewards_v2:end_epoch(T),
                MDRes = ct_rpc:call(Miner, blockchain_txn_rewards_v2, calculate_rewards_metadata, [
                    Start,
                    End,
                    Chain
                ]),
                case MDRes of
                    {ok, MD} ->
                        [{blockchain_block:height(Block), MD} | Acc];
                    _ ->
                        Acc
                end;
            _ ->
                Acc
        end
    end,
    Res = ct_rpc:call(Miner, blockchain, fold_chain, [Fun, [], Head, Chain]),
    Res.


get_rewards(Config) ->
    %% default to rewards_v1
    get_rewards(Config, blockchain_txn_rewards_v1).

get_rewards(Config, RewardType) ->
    [Miner | _] = ?config(miners, Config),
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(Miner, blockchain, blocks, [Chain]),
    maps:fold(fun(_, Block, Acc) ->
                      case blockchain_block:transactions(Block) of
                          [] ->
                              Acc;
                          Ts ->
                              Rewards = lists:filter(fun(T) ->
                                                             blockchain_txn:type(T) == RewardType
                                                     end,
                                                     Ts),
                              lists:flatten([Rewards | Acc])
                      end
              end,
              [],
              Blocks).

check_poc_rewards(RewardsTxns) ->
    %% Get all rewards types
    RewardTypes = lists:foldl(fun(RewardTxn, Acc) ->
                                      Types = [blockchain_txn_reward_v1:type(R) || R <- blockchain_txn_rewards_v1:rewards(RewardTxn)],
                                      lists:flatten([Types | Acc])
                              end,
                              [],
                              RewardsTxns),
    lists:any(fun(T) ->
                      T == poc_challengees orelse T == poc_witnesses
              end,
              RewardTypes).

do_common_partition_lying_checks(TestCase, Config, VarMap) ->
    Miners = ?config(miners, Config),
    %% Print scores before we begin the test
    InitialScores = gateway_scores(Config),
    ct:pal("InitialScores: ~p", [InitialScores]),
    %% Print scores before we begin the test
    InitialBalances = balances(Config),
    ct:pal("InitialBalances: ~p", [InitialBalances]),

    true = miner_ct_utils:wait_until(
             fun() ->
                     case maps:get(poc_version, VarMap, 1) of
                         V when V > 10 ->
                             %% Check that every miner has issued a challenge
                             C1 = check_all_miners_can_challenge(Miners),
                             %% Check that we have atleast more than one request
                             %% If we have only one request, there's no guarantee
                             %% that the paths would eventually grow
                             C2 = check_multiple_requests(Miners),
                             %% TODO: What to check when the partitioned nodes are lying about their locations
                             C1 andalso C2;
                         _ ->
                             %% Check that every miner has issued a challenge
                             C1 = check_all_miners_can_challenge(Miners),
                             %% Check that we have atleast more than one request
                             %% If we have only one request, there's no guarantee
                             %% that the paths would eventually grow
                             C2 = check_multiple_requests(Miners),
                             %% Since we have two static location partitioned networks, where
                             %% both are lying about their distances, the paths should
                             %% never get longer than 1
                             C3 = check_partitioned_lying_path_growth(TestCase, Miners),
                             C1 andalso C2 andalso C3
                     end
             end,
             40, 5000),
    %% Print scores after execution
    FinalScores = gateway_scores(Config),
    ct:pal("FinalScores: ~p", [FinalScores]),
    %% Print rewards
    Rewards = get_rewards(Config),
    ct:pal("Rewards: ~p", [Rewards]),
    %% Print balances after execution
    FinalBalances = balances(Config),
    ct:pal("FinalBalances: ~p", [FinalBalances]),
    %% There should be no poc_witness or poc_challengees rewards
    ?assert(not check_poc_rewards(Rewards)),
    ok.

extra_vars(poc_v11) ->
    POCVars = maps:merge(extra_vars(poc_v10), miner_poc_test_utils:poc_v11_vars()),
    RewardVars = #{reward_version => 5, rewards_txn_version => 2},
    maps:merge(POCVars, RewardVars);
extra_vars(poc_v10) ->
    maps:merge(extra_poc_vars(),
               #{?poc_version => 10,
                 ?data_aggregation_version => 2,
                 ?consensus_percent => 0.06,
                 ?dc_percent => 0.325,
                 ?poc_challengees_percent => 0.18,
                 ?poc_challengers_percent => 0.0095,
                 ?poc_witnesses_percent => 0.0855,
                 ?securities_percent => 0.34,
                 ?reward_version => 5,
                 ?rewards_txn_version => 2
                });
extra_vars(poc_v8) ->
    maps:merge(extra_poc_vars(), #{?poc_version => 8});
extra_vars(_) ->
    {error, poc_v8_and_above_only}.

location_sets(poc_dist_v11_partitioned_test) ->
    {sets:from_list(?AUSTINLOCS1), sets:from_list(?LALOCS)};
location_sets(poc_dist_v10_partitioned_test) ->
    {sets:from_list(?AUSTINLOCS1), sets:from_list(?LALOCS)};
location_sets(poc_dist_v8_partitioned_test) ->
    {sets:from_list(?AUSTINLOCS1), sets:from_list(?LALOCS)};
location_sets(_TestCase) ->
    {sets:from_list(?SFLOCS), sets:from_list(?NYLOCS)}.

extra_poc_vars() ->
    #{?poc_good_bucket_low => -132,
      ?poc_good_bucket_high => -80,
      ?poc_v5_target_prob_randomness_wt => 1.0,
      ?poc_v4_target_prob_edge_wt => 0.0,
      ?poc_v4_target_prob_score_wt => 0.0,
      ?poc_v4_prob_rssi_wt => 0.0,
      ?poc_v4_prob_time_wt => 0.0,
      ?poc_v4_randomness_wt => 0.5,
      ?poc_v4_prob_count_wt => 0.0,
      ?poc_centrality_wt => 0.5,
      ?poc_max_hop_cells => 2000}.

check_subsequent_path_growth(ReceiptMap) ->
    PathLengths = [ length(blockchain_txn_poc_receipts_v1:path(Txn)) || {_, Txn} <- lists:flatten(maps:values(ReceiptMap)) ],
    ct:pal("PathLengths: ~p", [PathLengths]),
    lists:any(fun(L) -> L > 1 end, PathLengths).
