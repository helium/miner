-module(miner_poc_v11_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
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
    BaseDir = ?config(base_dir, Config),

    {PrivKey, PubKey} = miner_ct_utils:new_random_key(ecc_compact),
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
    ConsensusMembers =
        [
            {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
        ] ++ RandomKeys,

    % Create genesis block
    Balance = 5000,
    CoinbaseTxns = [
        blockchain_txn_coinbase_v1:new(Addr, Balance)
     || {Addr, _} <- ConsensusMembers
    ],
    CoinbaseDCTxns = [
        blockchain_txn_dc_coinbase_v1:new(Addr, Balance)
     || {Addr, _} <- ConsensusMembers
    ],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new(
        [Addr || {Addr, _} <- ConsensusMembers],
        <<>>,
        1,
        0
    ),
    VarsKeys = libp2p_crypto:generate_keys(ecc_compact),
    VarsTx = miner_ct_utils:make_vars(VarsKeys, extra_vars()),

    Txs = CoinbaseTxns ++ CoinbaseDCTxns ++ [GenConsensusGroupTx] ++ VarsTx,
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

    ?assertEqual(requesting, erlang:element(1, sys:get_state(Statem))),
    % Blockchain is = to Chain
    ?assertEqual(Chain, erlang:element(3, erlang:element(2, sys:get_state(Statem)))),
    % State is requesting
    ?assertEqual(requesting, erlang:element(6, erlang:element(2, sys:get_state(Statem)))),

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
    ok = miner_poc_test_utils:send_receipts(LatLongs, Challengees),
    timer:sleep(100),

    ?assertEqual(receiving, erlang:element(6, erlang:element(2, sys:get_state(Statem)))),
    % Get reponses
    ?assert(maps:size(erlang:element(11, erlang:element(2, sys:get_state(Statem)))) > 0),

    % Passing receiving_timeout
    lists:foreach(
        fun(_) ->
            ok = miner_ct_utils:add_block(Chain, ConsensusMembers, []),
            timer:sleep(100)
        end,
        lists:seq(1, 20)
    ),

    ?assertEqual(receiving, erlang:element(1, sys:get_state(Statem))),
    % Get receiving_timeout
    ?assertEqual(0, erlang:element(12, erlang:element(2, sys:get_state(Statem)))),
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
