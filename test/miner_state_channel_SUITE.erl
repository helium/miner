-module(miner_state_channel_SUITE).

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
         all/0,
         groups/0,
         init_per_group/2,
         end_per_group/2
        ]).

-export([
         no_packets_expiry_test/1,
         packets_expiry_test/1,
         multi_clients_packets_expiry_test/1,
         multi_oui_test/1,
         replay_test/1,
         excess_spend_fail_test/1,
         conflict_test/1,
         reject_test/1,
         server_doesnt_close_test/1,
         client_reports_overspend_test/1,
         server_overspend_slash_test/1,
         ensure_dc_reward_during_grace_blocks/1
        ]).

%% common test callbacks

groups() ->
    [{sc_v1,
      [],
      test_cases()
     },
     {sc_v2,
      [],
      test_cases() ++ scv2_only_tests()
     }].

all() ->
    [{group, sc_v1}, {group, sc_v2}].

test_cases() ->
    [no_packets_expiry_test,
     packets_expiry_test,
     multi_clients_packets_expiry_test,
     multi_oui_test,
     replay_test
    ].

scv2_only_tests() ->
    [
     excess_spend_fail_test,
     conflict_test,
     reject_test,
     server_doesnt_close_test,
     client_reports_overspend_test,
     server_overspend_slash_test,
     server_doesnt_close_test,
     ensure_dc_reward_during_grace_blocks
    ].

init_per_group(sc_v1, Config) ->
    %% This is only for configuration and checking purposes
    [{sc_version, 1} | Config];
init_per_group(sc_v2, Config) ->
    SCVars = ?config(sc_vars, Config),
    %% NOTE: SC V2 also needs to have an election for reward payout
    SCV2Vars = maps:merge(SCVars,
                          #{?sc_version => 2,
                            ?sc_overcommit => 2,
                            ?election_interval => 8,
                            ?txn_fee_multiplier => 1,
                            ?dc_percent => 1.0,
                            ?consensus_percent => 0.0,
                            ?monthly_reward => 10000000 * 1000000,
                            ?sc_open_validation_bugfix => 1,
                            ?sc_causality_fix => 1,
                            ?reward_version => 4
                           }),
    [{sc_vars, SCV2Vars}, {sc_version, 2} | Config].

end_per_group(_, _Config) ->
    ok.

init_per_suite(Config) ->
    %% init_per_suite is the FIRST thing that runs and is common for both groups

    SCVars = #{?max_open_sc => 2,                    %% Max open state channels per router, set to 2
               ?min_expire_within => 2,              %% Min state channel expiration (# of blocks)
               ?max_xor_filter_size => 1024*100,     %% Max xor filter size, set to 1024*100
               ?max_xor_filter_num => 5,             %% Max number of xor filters, set to 5
               ?max_subnet_size => 65536,            %% Max subnet size
               ?min_subnet_size => 8,                %% Min subnet size
               ?max_subnet_num => 20,                %% Max subnet num
               ?dc_payload_size => 24,               %% DC payload size for calculating DCs
               ?sc_gc_interval => 12,
               ?sc_grace_blocks => 6},               %% Grace period (in num of blocks) for state channels to get GCd
    [{sc_vars, SCVars} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    Balance = 5000,
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    InitialDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    InitialPriceTxn = blockchain_txn_gen_price_oracle_v1:new(1000000),
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    RewardVars = case TestCase of
                     ensure_dc_reward_during_grace_blocks ->
                         maps:merge(#{ ?reward_version => 5, ?sc_grace_blocks => 10, ?election_interval => 30 , ?sc_gc_interval => 10},
                                    reward_vars()) ;
                     _ ->
                         %% rule out rewards
                         #{ ?election_interval => infinity }
                 end,

    BaseVars0 = #{?block_time => BlockTime,
                  ?num_consensus_members => NumConsensusMembers,
                  ?batch_size => BatchSize,
                  ?dkg_curve => Curve},

    SCVars = ?config(sc_vars, Config),
    ct:pal("SCVars: ~p", [SCVars]),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    AllVars = miner_ct_utils:make_vars(Keys, maps:merge(BaseVars0, maps:merge(SCVars, RewardVars))),
    ct:pal("AllVars: ~p", [AllVars]),

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners,
                                            AllVars ++ InitialPaymentTransactions ++ AddGwTxns ++ InitialDCTxns ++ [InitialPriceTxn],
                                            Addresses, NumConsensusMembers, Curve),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),

    ListenNode = lists:last(Miners),

    {ok, _Listener} = block_listener:start_link(ListenNode),
    %% might need to case this?
    ok = block_listener:register_txns([blockchain_txn_oui_v1,
                                       blockchain_txn_state_channel_open_v1,
                                       blockchain_txn_state_channel_close_v1]),
    ok = block_listener:register_listener(self()),

    RouterNode = hd(Miners),

    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    case TestCase of
        multi_oui_test ->
            %% this is complicated enough that we want to set up our
            %% own OUIs in this test.
            ok;
        _ ->
            EUIs = [{16#deadbeef, 16#deadc0de}, {16#beefbeef, 16#bad0bad0}],
            {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                                     AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- EUIs],
                                                 fun xxhash:hash64/1)),

            OUI = 1,
            OUITxn = ct_rpc:call(RouterNode,
                                 blockchain_txn_oui_v1,
                                 new,
                                 [OUI, RouterPubkeyBin, [RouterPubkeyBin], Filter, 8]),
            ct:pal("OUITxn: ~p", [OUITxn]),
            SignedOUITxn = ct_rpc:call(RouterNode,
                                       blockchain_txn_oui_v1,
                                       sign,
                                       [OUITxn, RouterSigFun]),
            ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
            ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

            %% check that oui txn appears on miners
            receive
                {blockchain_txn_oui_v1, HeightPrint, RecTxn} ->
                    ct:pal("oui at ~p", [HeightPrint]),
                    ?assertEqual(SignedOUITxn, RecTxn);
                Other ->
                    error({bad_txn, Other})
            after timer:seconds(30) ->
                    error(oui_timeout)
            end
    end,

    [{consensus_miners, ConsensusMiners},
     {router_node, {RouterNode, RouterPubkeyBin, RouterSigFun}},
     {non_consensus_miners, NonConsensusMiners},
     {default_routers, application:get_env(miner, default_routers, [])}
     | Config]
    catch
        What:Why ->
            end_per_testcase(TestCase, Config),
            erlang:What(Why)
    end.


end_per_testcase(TestCase, Config) ->
    ok = block_listener:stop(),
    miner_ct_utils:end_per_testcase(TestCase, Config),
    ct:pal("fin").

no_packets_expiry_test(Config) ->
    ExpireWithin = 4,
    _ID = open_state_channel(Config, ExpireWithin, 10),

    receive
        {blockchain_txn_state_channel_close_v1, _, _} ->
            ok;
        Other ->
            error({bad_txn, Other})
        after timer:seconds(30) ->
                error(sc_close_timeout)
    end,

    ok.

packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, _RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode | _] = tl(Miners),

    %% open a state channel
    _ID = open_state_channel(Config, 6, 10),
    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),
    timer:sleep(200),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    Height = miner_ct_utils:height(RouterNode),
    ct:pal("height post packets ~p", [Height]),

    %% for the state_channel_close txn to appear, ignore awful binding hack
    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,
    ct:pal("saw closed"),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 3),

    %% construct what the skewed merkle tree should look like
    Open = skewed:root_hash(skewed:new(OpenHash)),
    One = skewed:root_hash(skewed:add(Payload1, skewed:new(OpenHash))),
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    ct:pal("open ~p~none ~p", [Open, One]),

    %% assert the root hashes should match
    ?assertEqual(skewed:root_hash(ExpectedTree),
                 blockchain_state_channel_v1:root_hash(
                   blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn))),

    ok.

multi_clients_packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, _RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode1, ClientNode2 | _] = tl(Miners),

    %% open a state channel
    ExpireWithin = 6,
    Amount = 10,
    _ID = open_state_channel(Config, ExpireWithin, Amount),
    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),

    %% At this point, we're certain that sc is open
    %% Use client nodes to send some packets
    Packet1 = blockchain_helium_packet_v1:new(
                {eui, 16#deadbeef, 16#deadc0de}, <<"p1">>), %% first device joining
    Packet2 = blockchain_helium_packet_v1:new(
                {devaddr, 1207959553}, <<"p2">>), %% first device transmitting
    Packet3 = blockchain_helium_packet_v1:new(
                {eui, 16#beefbeef, 16#bad0bad0}, <<"p3">>), %% second device joining
    Packet4 = blockchain_helium_packet_v1:new(
                {devaddr, 1207959554}, <<"p4">>), %% second device transmitting
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet1, [], 'US915']), %% duplicate from client 2
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet4, [], 'US915']),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% construct what the skewed merkle tree should look like
    ExpectedTree = lists:foldl(fun(P, Acc) ->
                                       skewed:add(blockchain_helium_packet_v1:payload(P), Acc)
                               end,
                               skewed:new(OpenHash), [Packet1, Packet2, Packet3, Packet4]),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)), skewed:root_hash(ExpectedTree)),

    %% Check whether clientnode balance is correct

    ClientNodePubkeyBin1 = ct_rpc:call(ClientNode1, blockchain_swarm, pubkey_bin, []),
    ClientNodePubkeyBin2 = ct_rpc:call(ClientNode2, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin1, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin2, 3),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin1, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin2, 3),

    ok.

excess_spend_fail_test(Config) ->
    Miners = ?config(miners, Config),
    {_RouterNode, _RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode | _] = tl(Miners),

    %% open a state channel
    ExpireWithin = 6,
    Amount = 5,
    _ID = open_state_channel(Config, ExpireWithin, Amount),

    %% Use client node to send some packets
    lists:foreach(fun(N) -> send_packet(N, ClientNode, {devaddr, 1207959553}) end,
                  lists:seq(1,100)),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 5),
    ok.

replay_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, RouterPubkeyBin, RouterSigFun} = ?config(router_node, Config),

    [ClientNode | _] = tl(Miners),

    %% open a state channel
    ExpireWithin = 11,
    Amount = 10,
    _ID = open_state_channel(Config, ExpireWithin, Amount),

    %% Use client node to send some packets
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, <<"p2">>),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% I'm not sure we ever need this?
    %% ok = wait_for_gc(RouterNode, ID, RouterPubkeyBin, Config),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 2),

    %% re-create the sc open txn with the same nonce
    NewID = crypto:strong_rand_bytes(32),
    NewExpireWithin = 11,
    OUI = 1,
    Amount = 10,
    NewSCOpenTxn = ct_rpc:call(RouterNode,
                               blockchain_txn_state_channel_open_v1,
                               new,
                               [NewID, RouterPubkeyBin, NewExpireWithin, OUI, 1, Amount]),

    ct:pal("NewSCOpenTxn: ~p", [NewSCOpenTxn]),
    NewSignedSCOpenTxn = ct_rpc:call(RouterNode,
                                     blockchain_txn_state_channel_open_v1,
                                     sign,
                                     [NewSCOpenTxn, RouterSigFun]),
    ct:pal("NewSignedSCOpenTxn: ~p", [NewSignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [NewSignedSCOpenTxn]),

    receive
        {blockchain_txn_state_channel_open_v1, _, _RecTxn1} ->
            error(got_disallowed_open);
        Other1 ->
            error({bad_txn, Other1})
    after timer:seconds(30) ->
            ok
    end,

    ok.

multi_oui_test(Config) ->
    Miners = ?config(miners, Config),
    [RouterNode1, RouterNode2, ClientNode | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey1, RouterSigFun1, _ECDHFun1} = ct_rpc:call(RouterNode1, blockchain_swarm, keys, []),
    RouterPubkeyBin1 = libp2p_crypto:pubkey_to_bin(RouterPubkey1),
    RouterSwarm1 = ct_rpc:call(RouterNode1, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm1: ~p", [RouterSwarm1]),
    RouterP2PAddress1 = ct_rpc:call(RouterNode1, libp2p_swarm, p2p_address, [RouterSwarm1]),
    ct:pal("RouterP2PAddress1: ~p", [RouterP2PAddress1]),

    %% appears in both filters
    DevEUI1=rand:uniform(trunc(math:pow(2, 64))),
    AppEUI1=rand:uniform(trunc(math:pow(2, 64))),
    %% appears in only one filter
    DevEUI2=rand:uniform(trunc(math:pow(2, 64))),
    AppEUI2=rand:uniform(trunc(math:pow(2, 64))),
    %% appears in no filters
    DevEUI3=rand:uniform(trunc(math:pow(2, 64))),
    AppEUI3=rand:uniform(trunc(math:pow(2, 64))),

    {Filter1, _} = xor16:to_bin(xor16:new([<<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>], fun xxhash:hash64/1)),
    %% sanity check we don't have a false positive
    ?assert(xor16:contain({Filter1, fun xxhash:hash64/1}, <<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>)),
    ?assertNot(xor16:contain({Filter1, fun xxhash:hash64/1}, <<DevEUI2:64/integer-unsigned-little, AppEUI2:64/integer-unsigned-little>>)),
    ?assertNot(xor16:contain({Filter1, fun xxhash:hash64/1}, <<DevEUI3:64/integer-unsigned-little, AppEUI3:64/integer-unsigned-little>>)),

    OUI1 = 1,
    OUITxn1 = ct_rpc:call(RouterNode1,
                          blockchain_txn_oui_v1,
                          new,
                          [OUI1, RouterPubkeyBin1, [RouterPubkeyBin1], Filter1, 8]),
    ct:pal("OUITxn1: ~p", [OUITxn1]),
    SignedOUITxn1 = ct_rpc:call(RouterNode1,
                                blockchain_txn_oui_v1,
                                sign,
                                [OUITxn1, RouterSigFun1]),
    ct:pal("SignedOUITxn1: ~p", [SignedOUITxn1]),

    %% setup second oui txn
    {ok, RouterPubkey2, RouterSigFun2, _ECDHFun2} = ct_rpc:call(RouterNode2, blockchain_swarm, keys, []),
    RouterPubkeyBin2 = libp2p_crypto:pubkey_to_bin(RouterPubkey2),
    RouterSwarm2 = ct_rpc:call(RouterNode2, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm2: ~p", [RouterSwarm2]),
    RouterP2PAddress2 = ct_rpc:call(RouterNode2, libp2p_swarm, p2p_address, [RouterSwarm2]),
    ct:pal("RouterP2PAddress2: ~p", [RouterP2PAddress2]),

    {Filter2, _} = xor16:to_bin(xor16:new([<<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>,
                                          <<DevEUI2:64/integer-unsigned-little, AppEUI2:64/integer-unsigned-little>>], fun xxhash:hash64/1)),
    ?assert(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>)),
    ?assert(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI2:64/integer-unsigned-little, AppEUI2:64/integer-unsigned-little>>)),
    ?assertNot(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI3:64/integer-unsigned-little, AppEUI3:64/integer-unsigned-little>>)),

    OUI2 = 2,
    OUITxn2 = ct_rpc:call(RouterNode2,
                          blockchain_txn_oui_v1,
                          new,
                          [OUI2, RouterPubkeyBin2, [RouterPubkeyBin2], Filter2, 8]),
    ct:pal("OUITxn2: ~p", [OUITxn2]),
    SignedOUITxn2 = ct_rpc:call(RouterNode2,
                                blockchain_txn_oui_v1,
                                sign,
                                [OUITxn2, RouterSigFun2]),
    ct:pal("SignedOUITxn2: ~p", [SignedOUITxn2]),
    ok = ct_rpc:call(RouterNode1, blockchain_worker, submit_txn, [SignedOUITxn1]),
    receive
        {blockchain_txn_oui_v1, _, _} ->
            ok;
        Other ->
            error({bad_txn, Other})
    after timer:seconds(30) ->
            error(oui_timeout)
    end,
    ok = ct_rpc:call(RouterNode1, blockchain_worker, submit_txn, [SignedOUITxn2]),
    receive
        {blockchain_txn_oui_v1, HeightPrint, _} ->
            ct:pal("oui 2 at ~p", [HeightPrint]),
            ok;
        Other2 ->
            error({bad_txn, Other2})
    after timer:seconds(30) ->
            error(oui_timeout)
    end,

    %% open state channel 1
    ExpireWithin = 6,
    Amount = 10,
    ID1 = open_state_channel(Config, ExpireWithin, Amount),

    %% open state channel 2
    ExpireWithin2 = 12,
    ID2 = open_state_channel(Config, ExpireWithin2, Amount, 2),

    %% check state_channels from both nodes appears on the ledger
    {ok, SC1} = get_ledger_state_channel(RouterNode1, ID1, RouterPubkeyBin1),
    {ok, SC2} = get_ledger_state_channel(RouterNode2, ID2, RouterPubkeyBin2),
    true = check_ledger_state_channel(SC1, RouterPubkeyBin1, ID1, Config),
    true = check_ledger_state_channel(SC2, RouterPubkeyBin2, ID2, Config),
    true = miner_ct_utils:wait_until(
             fun() ->
                     [] /= ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_ids, []) andalso
                         [] /= ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_ids, [])
             end),
    ct:pal("SC1: ~p", [SC1]),
    ct:pal("SC2: ~p", [SC2]),

    DevAddrPrefix = application:get_env(blockchain, devaddr_prefix, $H),

    <<Addr1:32/integer-unsigned-little>> = <<1:25/integer-unsigned-little, DevAddrPrefix:7/integer>>,
    <<Addr2:32/integer-unsigned-little>> = <<9:25/integer-unsigned-little, DevAddrPrefix:7/integer>>,

    %% find the block that this SC opened in, we need the hash
    [{OpenHash2, _}, {OpenHash1, _}] = miner_ct_utils:get_txn_block_details(RouterNode1, fun check_type_sc_open/1),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload3 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload4 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload5 = crypto:strong_rand_bytes(rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, DevEUI1, AppEUI1}, Payload1), %% pretend this is a join, it will go to both ouis
    Packet2 = blockchain_helium_packet_v1:new({devaddr, Addr1}, Payload2), %% pretend this is a packet after join, only routes to oui 1
    Packet3 = blockchain_helium_packet_v1:new({devaddr, Addr2}, Payload3), %% pretend this is a packet after join, only routes to oui 2
    Packet4 = blockchain_helium_packet_v1:new({eui, DevEUI2, AppEUI2}, Payload4), %% pretend this is a join, it will go to oui 2
    Packet5 = blockchain_helium_packet_v1:new({eui, DevEUI3, AppEUI3}, Payload5), %% pretend this is a join, it will go to nobody

    %% Wait till client has an active sc
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID = ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_ids, []),
                     ct:pal("TempID: ~p", [TempID]),
                     TempID /= []
             end,
             60, 500),

    [ActiveSCID] = ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_ids, []),
    ct:pal("ActiveSCID: ~p", [ActiveSCID]),

    %% Sent two packets
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),

    SCCloseTxn1 =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other3 ->
                error({bad_txn, Other3}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% get this new active sc id
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID2 = ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_ids, []),
                     ct:pal("TempID2: ~p", [TempID2]),
                     TempID2 /= []
             end,
             60, 500),

    [ActiveSCID2] = ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_ids, []),
    ct:pal("ActiveSCID2: ~p", [ActiveSCID2]),

    %% we know whatever sc was active has closed now
    %% so send three more packets
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet4, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet5, [], 'US915']),

    %% check that the ids differ
    ?assertNotEqual(ActiveSCID, ActiveSCID2),

    SCCloseTxn2 =
        receive
            {blockchain_txn_state_channel_close_v1, CHT2, CloseTxn2} ->
                ct:pal("close height ~p", [CHT2]),
                CloseTxn2;
            Other4 ->
                error({bad_txn, Other4}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% construct what the skewed merkle tree should look like for the first state channel
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash1))),
    %% assert the root hashes should match
    ?assertEqual(skewed:root_hash(ExpectedTree),
                 blockchain_state_channel_v1:root_hash(
                   blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn1))),

    %% construct what the skewed merkle tree should look like for the second state channel
    ExpectedTree2 = skewed:add(Payload4, skewed:add(Payload3, skewed:add(Payload1, skewed:new(OpenHash2)))),
    %% assert the root hashes should match
    ?assertEqual(skewed:root_hash(ExpectedTree2),
                 blockchain_state_channel_v1:root_hash(
                   blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn2))),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn1), ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn1), ClientNodePubkeyBin, 3),

    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn2), ClientNodePubkeyBin, 3),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn2), ClientNodePubkeyBin, 4),

    ok.

conflict_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode, ClientNodeB | _] = tl(Miners),

    %% open a state channel
    ExpireWithin = 11,
    Amount = 10,
    ID = open_state_channel(Config, ExpireWithin, Amount),

    [InitialSC] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload3 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    Packet3 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload3), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),

    ct_rpc:call(RouterNode, blockchain_state_channels_server, insert_fake_sc_skewed, [InitialSC, skewed:new(OpenHash)]),
    ok = ct_rpc:call(ClientNodeB, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    ok = ct_rpc:call(ClientNodeB, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),
    ok = ct_rpc:call(ClientNodeB, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    true = miner_ct_utils:wait_until(
             fun() ->
                     {ok, SC2} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
                     ct:pal("close_state ~p ~p", [blockchain_ledger_state_channel_v2:close_state(SC2), SC2]),
                     blockchain_ledger_state_channel_v2:close_state(SC2) == dispute
             end, 120, 500),

    {ok, LSC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% ok = wait_for_gc(RouterNode, ID, RouterPubkeyBin, Config),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),
    ct:pal("LSC: ~p", [LSC]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    ClientNodeBPubkeyBin = ct_rpc:call(ClientNodeB, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_ledger_state_channel_v2:state_channel(LSC), ClientNodePubkeyBin, 2),
    true = check_sc_num_packets(blockchain_ledger_state_channel_v2:state_channel(LSC), ClientNodeBPubkeyBin, 3),

    ok.

reject_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode | _] = tl(Miners),

    %% open a state channel
    ExpireWithin = 11,
    Amount = 10,
    ID = open_state_channel(Config, ExpireWithin, Amount),

    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload3 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    Packet3 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload3), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ct_rpc:call(RouterNode, application, set_env, [blockchain, sc_packet_handler_offer_fun, fun(Offer) -> lager:info("rejecting offer ~p", [Offer]), {error, nope} end]),
    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    timer:sleep(500),
    ct_rpc:call(RouterNode, application, unset_env, [blockchain, sc_packet_handler_offer_fun]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    ok = wait_for_gc(RouterNode, ID, RouterPubkeyBin, Config),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 3),

    %% construct what the skewed merkle tree should look like
    ExpectedTree = skewed:add(Payload3, skewed:add(Payload1, skewed:new(OpenHash))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)), skewed:root_hash(ExpectedTree)),

    ok.

server_doesnt_close_test(Config) ->
    Miners = ?config(miners, Config),
    {RouterNode, _RouterPubkeyBin, _} = ?config(router_node, Config),
    [ClientNode | _] = tl(Miners),

    ExpireWithin = 6,
    Amount = 10,
    _ID = open_state_channel(Config, ExpireWithin, Amount),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    timer:sleep(1000),

    %% stop the miner so it cannot send the close
    miner_ct_utils:stop_miners([RouterNode]),  % can we wait here?
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(ClientNode, fun check_type_sc_open/1),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(60) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 3),

    %% construct what the skewed merkle tree should look like
    Open = skewed:root_hash(skewed:new(OpenHash)),
    One = skewed:root_hash(skewed:add(Payload1, skewed:new(OpenHash))),
    ct:pal("open ~p~none ~p", [Open, One]),

    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    %% assert the root hashes should match
    ?assertEqual(skewed:root_hash(ExpectedTree),
                 blockchain_state_channel_v1:root_hash(
                   blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn))),
    ok.

client_reports_overspend_test(Config) ->
    Miners = ?config(miners, Config),

    {_RouterNode, RouterPubkeyBin, _} = ?config(router_node, Config),
    [ClientNode | _] = tl(Miners),

    ExpireWithin = 6,
    Amount = 2,
    ID = open_state_channel(Config, ExpireWithin, Amount),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload3 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    Packet3 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload3), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    timer:sleep(500),
    %% client will probably not even send this
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet3, [], 'US915']),

    _SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    %% check we ended up in a dispute
    {ok, LSC} = get_ledger_state_channel(ClientNode, ID, RouterPubkeyBin),
    ct:pal("close_state ~p ~p", [blockchain_ledger_state_channel_v2:close_state(LSC), LSC]),
    ?assertEqual(dispute, blockchain_ledger_state_channel_v2:close_state(LSC)),

    ok.

server_overspend_slash_test(Config) ->
    Miners = ?config(miners, Config),
    SCOvercommit = maps:get(?sc_overcommit, ?config(sc_vars, Config)),
    {RouterNode, RouterPubkeyBin, RouterSigFun} = ?config(router_node, Config),

    [ClientNode |_] = tl(Miners),

    Ledger = ct_rpc:call(RouterNode, blockchain, ledger, []),

    ?assertEqual({ok, 1000000}, ct_rpc:call(RouterNode, blockchain_ledger_v1, current_oracle_price, [Ledger])),

    InitialBalance = miner_ct_utils:get_dc_balance(RouterNode, RouterPubkeyBin),

    ClientPubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),

    %% open a state channel
    ExpireWithin = 11,
    Amount = 1, %% needs to be small to avoid proportional payout
    ID = open_state_channel(Config, ExpireWithin, Amount),

    [InitialSC] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),

    NewSummary = blockchain_state_channel_summary_v1:new(ClientPubkeyBin, Amount * 2, Amount * 2),
    {OverSpentSC, true} = blockchain_state_channel_v1:update_summary_for(ClientPubkeyBin, NewSummary, InitialSC, true, 2000),
    SignedOverSpentSC = blockchain_state_channel_v1:sign(OverSpentSC, RouterSigFun),
    ok = blockchain_state_channel_v1:validate(SignedOverSpentSC),

    ct:pal("NSC: ~p", [SignedOverSpentSC]),

    ct_rpc:call(RouterNode, blockchain_state_channels_server, insert_fake_sc_skewed, [SignedOverSpentSC, skewed:new(OpenHash)]),

    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    true = miner_ct_utils:wait_until(
             fun() ->
                     {ok, SC2} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
                     ct:pal("close_state ~p ~p", [blockchain_ledger_state_channel_v2:close_state(SC2), SC2]),
                     blockchain_ledger_state_channel_v2:close_state(SC2) == dispute
             end, 120, 500),

    {ok, LSC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% ok = wait_for_gc(RouterNode, ID, RouterPubkeyBin, Config),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),
    ct:pal("LSC: ~p", [LSC]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_ledger_state_channel_v2:state_channel(LSC), ClientNodePubkeyBin, Amount * 2),


    ok = block_listener:register_txns([blockchain_txn_rewards_v1]),

    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2),

    RwdTxn1 =
        receive
            {blockchain_txn_rewards_v1, CHT2, RwdTxn} ->
                ct:pal("reward height ~p", [CHT2]),
                RwdTxn;
            Other3 ->
                error({bad_txn, Other3}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,

    ?assertNotEqual(undefined, RwdTxn1),

    ct:pal("Rwd: ~p", [RwdTxn1]),

    [DCReward] = lists:filter(fun(R) ->
                                      blockchain_txn_reward_v1:type(R) == data_credits andalso blockchain_txn_reward_v1:gateway(R) == ClientPubkeyBin
                              end, blockchain_txn_rewards_v1:rewards(RwdTxn1)),

    ct:pal("DC reward: ~p", [DCReward]),

    %% check how much HNT the gateway earned
    RewardInHNT = blockchain_txn_reward_v1:amount(DCReward),
    {ok, RewardInDC} = ct_rpc:call(RouterNode, blockchain_ledger_v1, hnt_to_dc, [RewardInHNT, Ledger]),
    {ok, SCAmountInHNT} = ct_rpc:call(RouterNode, blockchain_ledger_v1, dc_to_hnt, [Amount, Ledger]),
    {ok, SCTotalInHNT} = ct_rpc:call(RouterNode, blockchain_ledger_v1, dc_to_hnt, [Amount*2, Ledger]),

    ct:pal("RewardInDC ~p", [RewardInDC]),
    ct:pal("SCAmountInHNT ~p", [SCAmountInHNT]),
    ct:pal("SCTotalInHNT ~p", [SCTotalInHNT]),

    %% check the state channel didn't pay out more than the max amount
    ?assertEqual(RewardInHNT, SCAmountInHNT),

    FinalBalance = miner_ct_utils:get_dc_balance(RouterNode, RouterPubkeyBin),

    ct:pal("Initial ~p Final ~p", [InitialBalance, FinalBalance]),

    %% check the router node balance is down by Amount * Overcommit
    %% which means its overcommit got slashed
    ?assertEqual(InitialBalance - (Amount * SCOvercommit), FinalBalance),

    ok.


%% Helper functions

open_state_channel(Config, ExpireWithin, Amount) ->
    open_state_channel(Config, ExpireWithin, Amount, 1).

open_state_channel(Config, ExpireWithin, Amount, OUI) ->
    ID = crypto:strong_rand_bytes(32),
    {RouterNode, RouterPubkeyBin, RouterSigFun} =
        case OUI of
            1 -> ?config(router_node, Config);
            N ->
                Node = lists:nth(N, ?config(miners, Config)),
                {ok, RouterPubkey, SigFun, _ECDHFun} = ct_rpc:call(Node, blockchain_swarm, keys, []),
                PubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
                {Node, PubkeyBin, SigFun}
        end,

    Nonce = 1,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, OUI, Nonce, Amount]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    receive
        {blockchain_txn_state_channel_open_v1, HeightPrint1, RecTxn1} ->
            ct:pal("State channel opened at ~p", [HeightPrint1]),
            ?assertEqual(SignedSCOpenTxn, RecTxn1);
        Other1 ->
            error({bad_txn, Other1})
    after timer:seconds(30) ->
            error(sc_open_timeout)
    end,

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, ID, Config),
    %% wait for the state channel server to init
    true = miner_ct_utils:wait_until(
             fun() ->
                     [] /= ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, [])
             end),
    HeightPrint2 = miner_ct_utils:height(RouterNode),
    ct:pal("State channel active at ~p", [HeightPrint2]),

    ct:pal("SC: ~p", [SC]),
    ID.

ensure_dc_reward_during_grace_blocks(Config) ->
    %% NOTE: This test may give a false positive because the check at the bottom doesn't truly verify that the state channel close is within next epoch start - grace period. However, it should always pass when reward_version=5 implying that the dc_reward would be paid out regardless of whether it was within the grace period or not.

    Miners = ?config(miners, Config),
    {RouterNode, _RouterPubkeyBin, _} = ?config(router_node, Config),

    [ClientNode | _] = tl(Miners),

    %% open a state channel
    _ID = open_state_channel(Config, 15, 10),
    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, fun check_type_sc_open/1),
    timer:sleep(200),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, [], 'US915']),
    timer:sleep(500),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, [], 'US915']),
    Height = miner_ct_utils:height(RouterNode),
    ct:pal("height post packets ~p", [Height]),

    %% for the state_channel_close txn to appear, ignore awful binding hack
    SCCloseTxn =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other2 ->
                error({bad_txn, Other2}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,
    ct:pal("saw closed"),

    %% Check whether the balances are updated in the eventual sc close txn
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn), ClientNodePubkeyBin, 3),

    %% construct what the skewed merkle tree should look like
    Open = skewed:root_hash(skewed:new(OpenHash)),
    One = skewed:root_hash(skewed:add(Payload1, skewed:new(OpenHash))),
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    ct:pal("open ~p~none ~p", [Open, One]),

    %% assert the root hashes should match
    ?assertEqual(skewed:root_hash(ExpectedTree),
                 blockchain_state_channel_v1:root_hash(
                   blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn))),

    %% 2 epochs should have happened when we hit height 70
    ok = miner_ct_utils:wait_for_gte(height, Miners, 70, all, 60*5),

    RewardTxns = get_reward_txns(ClientNode),
    ct:pal("RewardTxns: ~p", [RewardTxns]),

    DCRewards = lists:foldl(
                  fun(E, Acc) ->
                          Rewards = blockchain_txn_rewards_v1:rewards(E),
                          [blockchain_txn_reward_v1:amount(R) || R <- Rewards,
                                    blockchain_txn_reward_v1:type(R) == data_credits] ++ Acc
                  end, [], RewardTxns),
    ct:pal("DCRewards: ~p", [DCRewards]),

    case length(DCRewards) > 0 of
        false -> ct:fail("DC rewards contained no values");
        true -> ok
    end.

%% Helper functions
send_packet(N, Client, Addr) ->
    Nbin = integer_to_binary(N),
    Payload = <<"p", Nbin/binary>>,
    Packet = blockchain_helium_packet_v1:new(Addr, Payload),
    ok = ct_rpc:call(Client, blockchain_state_channels_client, packet, [Packet, [], 'US915']),
    timer:sleep(1), % yield
    ok.

get_ledger_state_channel(Node, SCID, PubkeyBin) ->
    RouterChain = ct_rpc:call(Node, blockchain_worker, blockchain, []),
    RouterLedger = ct_rpc:call(Node, blockchain, ledger, [RouterChain]),
    fun Loop(0) ->
            {error, not_found};
        Loop(N) ->
            case ct_rpc:call(Node, blockchain_ledger_v1, find_state_channel, [SCID, PubkeyBin, RouterLedger]) of
                {ok, SC} ->
                    {ok, SC};
                {error, _} ->
                    timer:sleep(100),
                    Loop(N - 1)
            end
    end(100). % 10s

check_ledger_state_channel(LedgerSC, OwnerPubkeyBin, SCID, Config) ->
    LedgerSCMod = ledger_sc_mod(Config),
    CheckId = SCID == LedgerSCMod:id(LedgerSC),
    CheckOwner = OwnerPubkeyBin == LedgerSCMod:owner(LedgerSC),
    CheckId andalso CheckOwner.

%% print_hbbft_buf({ok, Txns}) ->
%%     [blockchain_txn:deserialize(T) || T <- Txns].

%% print_txn_mgr_buf(Txns) ->
%%     [{Txn, length(Accepts), length(Rejects)} || {Txn, {_Callback, Accepts, Rejects, _Dialers}} <- Txns].

check_sc_num_packets(SC, ClientPubkeyBin, ExpectedNumPackets) ->
    {ok, NumPackets} = blockchain_state_channel_v1:num_packets_for(ClientPubkeyBin, SC),
    case ExpectedNumPackets == NumPackets of
        true ->
            true;
        _ ->
            ct:fail({ExpectedNumPackets, NumPackets})
    end.

check_sc_num_dcs(SC, ClientPubkeyBin, ExpectedNumDCs) ->
    {ok, NumDCs} = blockchain_state_channel_v1:num_dcs_for(ClientPubkeyBin, SC),
    case ExpectedNumDCs == NumDCs of
        true ->
            true;
        _ ->
            ct:fail({ExpectedNumDCs, NumDCs})
    end.

ledger_sc_mod(Config) ->
    case ?config(sc_version, Config) of
        1 -> blockchain_ledger_state_channel_v1;
        2 -> blockchain_ledger_state_channel_v2
    end.

wait_for_gc(Node, ID, PubkeyBin, Config) ->
    %% If we are not running sc_version=1, we need to wait for the gc to trigger
    case ?config(sc_version, Config) of
        1 ->
            ok;
        _ ->
            SCVars = ?config(sc_vars, Config),
            Miners = ?config(miners, Config),
            Height = miner_ct_utils:height(lists:last(Miners)),
            Int = maps:get(?sc_gc_interval, SCVars),
            Div = Height div Int,
            ok = miner_ct_utils:wait_for_gte(height, tl(Miners), (Int * (Div + 1)), all, Int * 2),
            %% check state_channel is removed once the close txn appears
            true = miner_ct_utils:wait_until(
                     fun() ->
                             {error, not_found} == get_ledger_state_channel(Node, ID, PubkeyBin)
                     end, 30*5, 200),
            ok
    end.

check_type_sc_open(T) ->
    blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1.

%% debug(Node) ->
%%     Chain = ct_rpc:call(Node, blockchain_worker, blockchain, []),
%%     Blocks = ct_rpc:call(Node, blockchain, blocks, [Chain]),
%%     lists:foreach(fun(Block) ->
%%                           H = blockchain_block:height(Block),
%%                           Ts = blockchain_block:transactions(Block),
%%                           ct:pal("H: ~p, Ts: ~p", [H, Ts])
%%                   end, maps:values(Blocks)).


reward_vars() ->
    %% Taken from the chain at height: 534504
    #{ consensus_percent => 0.06,
       dc_percent => 0.325,
       poc_challengees_percent => 0.18,
       poc_challengers_percent => 0.0095,
       poc_witnesses_percent => 0.0855,
       securities_percent => 0.34
     }.

get_reward_txns(Node) ->
    Chain = ct_rpc:call(Node, blockchain_worker, blockchain, []),
    Blocks = ct_rpc:call(Node, blockchain, blocks, [Chain]),

    miner_ct_utils:get_txns(Blocks,
                            fun(T) -> blockchain_txn:type(T) == blockchain_txn_rewards_v1 end).
