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
         all/0
        ]).

-export([
         no_packets_expiry_test/1,
         packets_expiry_test/1,
         multi_clients_packets_expiry_test/1,
         replay_test/1
        ]).

%% common test callbacks

all() -> [
          no_packets_expiry_test,
          packets_expiry_test,
          multi_clients_packets_expiry_test,
          replay_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Balance = 5000,
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    InitialDCTxns = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addresses],
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 || Addr <- Addresses],

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    SCVars = #{max_open_sc => 2,
               min_expire_within => 10,
               max_xor_filter_size => 1024*100,
               max_xor_filter_num => 5,
               max_subnet_size => 65536,
               min_subnet_size => 8,
               max_subnet_num => 20,
               sc_grace_blocks => 5},

    DefaultVars = #{?block_time => BlockTime,
                    %% rule out rewards
                    ?election_interval => infinity,
                    ?num_consensus_members => NumConsensusMembers,
                    ?batch_size => BatchSize,
                    ?dkg_curve => Curve},

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, maps:merge(DefaultVars, SCVars)),

    DKGResults = miner_ct_utils:inital_dkg(Miners,
                                           InitialVars ++ InitialPaymentTransactions ++ AddGwTxns ++ InitialDCTxns,
                                           Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    %% confirm we have a height of 1
    ok = miner_ct_utils:wait_for_gte(height_exactly, Miners, 1),

    [{consensus_miners, ConsensusMiners},
     {non_consensus_miners, NonConsensusMiners},
     {default_routers, application:get_env(miner, default_routers, [])}
     | Config].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

no_packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),

    [RouterNode | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    ct:pal("Height before oui: ~p", [miner_ct_utils:height(RouterNode)]),

    EUIs = [{16#deadbeef, 16#deadc0de}],
    {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                             AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- EUIs],
                                         fun xxhash:hash64/1)),

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, 1, 0]),
    ct:pal("OUITxn: ~p", [OUITxn]),
    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    ct:pal("Height after oui: ~p", [miner_ct_utils:height(RouterNode)]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(120)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(120)),

    Height = miner_ct_utils:height(RouterNode),

    %% open a state channel
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 11,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, 1, 1]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen = fun(T) -> T == SignedSCOpenTxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, ID),
    ct:pal("SC: ~p", [SC]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

    %% check state_channel is removed once the close txn appears
    {error, not_found} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    ok.

packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),
    DefaultRouters = ?config(default_routers, Config),

    [RouterNode, ClientNode | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    EUIs = [{16#deadbeef, 16#deadc0de}],
    {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                             AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- EUIs],
                                         fun xxhash:hash64/1)),

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, 1, 0]),
    ct:pal("OUITxn: ~p", [OUITxn]),
    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(30)),

    Height = miner_ct_utils:height(RouterNode),

    %% open a state channel
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, 1, 1]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen = fun(T) -> T == SignedSCOpenTxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1}, Payload1),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1}, Payload2),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, DefaultRouters]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, DefaultRouters]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(30)),

    %% check state_channel is removed once the close txn appears
    {error, not_found} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_ct_utils:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCOpen),

    %% construct what the skewed merkle tree should look like
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)), skewed:root_hash(ExpectedTree)),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin, 3),

    ok.

multi_clients_packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),
    DefaultRouters = ?config(default_routers, Config),

    [RouterNode, ClientNode1, ClientNode2 | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    EUIs = [{16#deadbeef, 16#deadc0de}],
    {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                             AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- EUIs],
                                         fun xxhash:hash64/1)),

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, 1, 0]),
    ct:pal("OUITxn: ~p", [OUITxn]),
    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(30)),


    %% open a state channel
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, 1, 1]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen = fun(T) -> T == SignedSCOpenTxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

    %% make sure the router node has it too
    ok = miner_ct_utils:wait_for_txn([RouterNode], CheckTxnSCOpen, timer:seconds(30)),
    Height = miner_ct_utils:height(RouterNode),
    ct:pal("State channel opened at ~p", [Height]),

    %% At this point, we're certain that sc is open
    %% Use client nodes to send some packets
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p2">>),
    Packet3 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p3">>),
    Packet4 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p4">>),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet1, DefaultRouters]),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet2, DefaultRouters]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet1, DefaultRouters]), %% duplicate from client 2
    timer:sleep(1000), %% this should help prevent a race condition over merkle tree order
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet3, DefaultRouters]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet4, DefaultRouters]),

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, ID),
    ct:pal("SC: ~p", [SC]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3, all, 100),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    try miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(60)) of
        ok -> ok
    catch _:_ ->
              ct:pal("Txn manager: ~p", [print_txn_mgr_buf(ct_rpc:call(RouterNode, blockchain_txn_mgr, txn_list, []))]),
              [ ct:pal("Hbbft buf ~p ~p", [Miner, print_hbbft_buf(ct_rpc:call(Miner, miner_consensus_mgr, txn_buf, []))]) || Miner <- Miners],
              ct:fail("failed")
    end,

    %% check state_channel is removed once the close txn appears
    {error, not_found} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_ct_utils:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash, _}] = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCOpen),

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
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin1, 2),
    true = check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin2, 3),
    true = check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin1, 2),
    true = check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin2, 3),

    ok.

replay_test(Config) ->
    Miners = ?config(miners, Config),
    DefaultRouters = ?config(default_routers, Config),

    [RouterNode, ClientNode | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    EUIs = [{16#deadbeef, 16#deadc0de}],
    {Filter, _} = xor16:to_bin(xor16:new([ <<DevEUI:64/integer-unsigned-little,
                                             AppEUI:64/integer-unsigned-little>> || {DevEUI, AppEUI} <- EUIs],
                                         fun xxhash:hash64/1)),

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [RouterPubkeyBin], Filter, 8, 1, 0]),
    ct:pal("OUITxn: ~p", [OUITxn]),
    SignedOUITxn = ct_rpc:call(RouterNode,
                               blockchain_txn_oui_v1,
                               sign,
                               [OUITxn, RouterSigFun]),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedOUITxn]),

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(120)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(120)),

    Height = miner_ct_utils:height(RouterNode),

    %% open a state channel
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenNonce = 1,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, ExpireWithin, 1, SCOpenNonce]),
    ct:pal("SCOpenTxn: ~p", [SCOpenTxn]),
    SignedSCOpenTxn = ct_rpc:call(RouterNode,
                                  blockchain_txn_state_channel_open_v1,
                                  sign,
                                  [SCOpenTxn, RouterSigFun]),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [SignedSCOpenTxn]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen = fun(T) -> T == SignedSCOpenTxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(120)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(120)),

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1}, <<"p2">>),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, DefaultRouters]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, DefaultRouters]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(120)),

    %% check state_channel is removed once the close txn appears
    {error, not_found} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_ct_utils:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 2),

    %% re-create the sc open txn with the same nonce
    NewID = crypto:strong_rand_bytes(32),
    NewExpireWithin = 5,
    NewSCOpenTxn = ct_rpc:call(RouterNode,
                               blockchain_txn_state_channel_open_v1,
                               new,
                               [NewID, RouterPubkeyBin, NewExpireWithin, SCOpenNonce]),

    ct:pal("NewSCOpenTxn: ~p", [NewSCOpenTxn]),
    NewSignedSCOpenTxn = ct_rpc:call(RouterNode,
                                     blockchain_txn_state_channel_open_v1,
                                     sign,
                                     [NewSCOpenTxn, RouterSigFun]),
    ct:pal("NewSignedSCOpenTxn: ~p", [NewSignedSCOpenTxn]),
    ok = ct_rpc:call(RouterNode, blockchain_worker, submit_txn, [NewSignedSCOpenTxn]),

    %% check that this replayed sc open txn does NOT appear on miners
    NewCheckTxnSCOpen = fun(T) -> T == NewSignedSCOpenTxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, NewCheckTxnSCOpen, timer:seconds(120), false),

    ok.


%% Helper functions

get_ledger_state_channel(Node, SCID, PubkeyBin) ->
    RouterChain = ct_rpc:call(Node, blockchain_worker, blockchain, []),
    RouterLedger = ct_rpc:call(Node, blockchain, ledger, [RouterChain]),
    ct_rpc:call(Node, blockchain_ledger_v1, find_state_channel, [SCID, PubkeyBin, RouterLedger]).

check_ledger_state_channel(LedgerSC, OwnerPubkeyBin, SCID) ->
    CheckId = SCID == blockchain_ledger_state_channel_v1:id(LedgerSC),
    CheckOwner = OwnerPubkeyBin == blockchain_ledger_state_channel_v1:owner(LedgerSC),
    CheckId andalso CheckOwner.

print_hbbft_buf({ok, Txns}) ->
    [blockchain_txn:deserialize(T) || T <- Txns].

print_txn_mgr_buf(Txns) ->
    [{Txn, length(Accepts), length(Rejects)} || {Txn, {_Callback, Accepts, Rejects, _Dialers}} <- Txns].

check_sc_num_packets(SCCloseTxn, ClientPubkeyBin, ExpectedNumPackets) ->
    SC = blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn),
    {ok, NumPackets} = blockchain_state_channel_v1:num_packets_for(ClientPubkeyBin, SC),
    ExpectedNumPackets == NumPackets.

check_sc_num_dcs(SCCloseTxn, ClientPubkeyBin, ExpectedNumDCs) ->
    SC = blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn),
    {ok, NumDCs} = blockchain_state_channel_v1:num_dcs_for(ClientPubkeyBin, SC),
    ExpectedNumDCs == NumDCs.
