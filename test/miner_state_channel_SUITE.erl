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
         multi_oui_test/1,
         replay_test/1
        ]).

%% common test callbacks

all() -> [
          no_packets_expiry_test,
          packets_expiry_test,
          multi_clients_packets_expiry_test,
          multi_oui_test,
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

    SCVars = #{?max_open_sc => 2,                    %% Max open state channels per router, set to 2
               ?min_expire_within => 10,             %% Min state channel expiration (# of blocks)
               ?max_xor_filter_size => 1024*100,     %% Max xor filter size, set to 1024*100
               ?max_xor_filter_num => 5,             %% Max number of xor filters, set to 5
               ?max_subnet_size => 65536,            %% Max subnet size
               ?min_subnet_size => 8,                %% Min subnet size
               ?max_subnet_num => 20,                %% Max subnet num
               ?dc_payload_size => 24,               %% DC payload size for calculating DCs
               ?sc_grace_blocks => 5},               %% Grace period (in num of blocks) for state channels to get GCd

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
    %% Construct an exor filter to check membership where to route a packet based on their deveui and appeui
    %% Additionaly hash the inputs and convert the filter to a binary for sending over the wire
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
    Packet1 = blockchain_helium_packet_v1:new({eui, 16#deadbeef, 16#deadc0de}, Payload1), %% pretend this is a join
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, []]),

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

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(SCCloseTxn, ClientNodePubkeyBin, 3),

    %% construct what the skewed merkle tree should look like
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)), skewed:root_hash(ExpectedTree)),

    ok.

multi_clients_packets_expiry_test(Config) ->
    Miners = ?config(miners, Config),

    [RouterNode, ClientNode1, ClientNode2 | _] = Miners,

    %% setup
    %% oui txn
    {ok, RouterPubkey, RouterSigFun, _ECDHFun} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm: ~p", [RouterSwarm]),
    RouterP2PAddress = ct_rpc:call(RouterNode, libp2p_swarm, p2p_address, [RouterSwarm]),
    ct:pal("RouterP2PAddress: ~p", [RouterP2PAddress]),

    {Filter, _} = xor16:to_bin(xor16:new([<<1234:64/integer-unsigned-little, 5678:64/integer-unsigned-little>>,
                                          <<16#dead:64/integer-unsigned-little, 16#beef:64/integer-unsigned-little>>
                                         ], fun xxhash:hash64/1)),

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
    Packet1 = blockchain_helium_packet_v1:new({eui, 1234, 5678}, <<"p1">>), %% first device joining
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, <<"p2">>), %% first device transmitting
    Packet3 = blockchain_helium_packet_v1:new({eui, 16#dead, 16#beef}, <<"p3">>), %% second device joining
    Packet4 = blockchain_helium_packet_v1:new({devaddr, 1207959554}, <<"p4">>), %% second device transmitting
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet1, []]),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet2, []]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet1, []]), %% duplicate from client 2
    timer:sleep(1000), %% this should help prevent a race condition over merkle tree order
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet3, []]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet4, []]),

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
    Packet1 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, <<"p2">>),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, []]),

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
                               [NewID, RouterPubkeyBin, NewExpireWithin, 1, SCOpenNonce]),

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

    OUITxn1 = ct_rpc:call(RouterNode1,
                          blockchain_txn_oui_v1,
                          new,
                          [RouterPubkeyBin1, [RouterPubkeyBin1], Filter1, 8, 1, 0]),
    ct:pal("OUITxn1: ~p", [OUITxn1]),
    SignedOUITxn1 = ct_rpc:call(RouterNode1,
                                blockchain_txn_oui_v1,
                                sign,
                                [OUITxn1, RouterSigFun1]),
    ct:pal("SignedOUITxn1: ~p", [SignedOUITxn1]),
    ok = ct_rpc:call(RouterNode1, blockchain_worker, submit_txn, [SignedOUITxn1]),

    %% setup second oui txn
    {ok, RouterPubkey2, RouterSigFun2, _ECDHFun2} = ct_rpc:call(RouterNode2, blockchain_swarm, keys, []),
    RouterPubkeyBin2 = libp2p_crypto:pubkey_to_bin(RouterPubkey2),
    RouterSwarm2 = ct_rpc:call(RouterNode2, blockchain_swarm, swarm, []),
    ct:pal("RouterSwarm2: ~p", [RouterSwarm2]),
    RouterP2PAddress2 = ct_rpc:call(RouterNode2, libp2p_swarm, p2p_address, [RouterSwarm2]),
    ct:pal("RouterP2PAddress2: ~p", [RouterP2PAddress2]),
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI1 = fun(T) -> T == SignedOUITxn1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI1, timer:seconds(30)),

    {Filter2, _} = xor16:to_bin(xor16:new([<<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>,
                                          <<DevEUI2:64/integer-unsigned-little, AppEUI2:64/integer-unsigned-little>>], fun xxhash:hash64/1)),
    ?assert(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI1:64/integer-unsigned-little, AppEUI1:64/integer-unsigned-little>>)),
    ?assert(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI2:64/integer-unsigned-little, AppEUI2:64/integer-unsigned-little>>)),
    ?assertNot(xor16:contain({Filter2, fun xxhash:hash64/1}, <<DevEUI3:64/integer-unsigned-little, AppEUI3:64/integer-unsigned-little>>)),

    OUITxn2 = ct_rpc:call(RouterNode2,
                          blockchain_txn_oui_v1,
                          new,
                          [RouterPubkeyBin2, [RouterPubkeyBin2], Filter2, 8, 1, 0]),
    ct:pal("OUITxn2: ~p", [OUITxn2]),
    SignedOUITxn2 = ct_rpc:call(RouterNode2,
                                blockchain_txn_oui_v1,
                                sign,
                                [OUITxn2, RouterSigFun2]),
    ct:pal("SignedOUITxn2: ~p", [SignedOUITxn2]),
    ok = ct_rpc:call(RouterNode2, blockchain_worker, submit_txn, [SignedOUITxn2]),

    %% check that oui txn appears on miners
    CheckTxnOUI2 = fun(T) -> T == SignedOUITxn2 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI2, timer:seconds(30)),

    Height = miner_ct_utils:height(RouterNode1),

    %% open state channel 1
    ID1 = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn1 = ct_rpc:call(RouterNode1,
                             blockchain_txn_state_channel_open_v1,
                             new,
                             [ID1, RouterPubkeyBin1, ExpireWithin, 1, 1]),
    ct:pal("SCOpenTxn1: ~p", [SCOpenTxn1]),
    SignedSCOpenTxn1 = ct_rpc:call(RouterNode1,
                                   blockchain_txn_state_channel_open_v1,
                                   sign,
                                   [SCOpenTxn1, RouterSigFun1]),
    ct:pal("SignedSCOpenTxn1: ~p", [SignedSCOpenTxn1]),
    ok = ct_rpc:call(RouterNode1, blockchain_worker, submit_txn, [SignedSCOpenTxn1]),

    %% open state channel 2
    ID2 = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn2 = ct_rpc:call(RouterNode1,
                             blockchain_txn_state_channel_open_v1,
                             new,
                             [ID2, RouterPubkeyBin2, ExpireWithin, 2, 1]),
    ct:pal("SCOpenTxn2: ~p", [SCOpenTxn2]),
    SignedSCOpenTxn2 = ct_rpc:call(RouterNode2,
                                   blockchain_txn_state_channel_open_v1,
                                   sign,
                                   [SCOpenTxn2, RouterSigFun2]),
    ct:pal("SignedSCOpenTxn2: ~p", [SignedSCOpenTxn2]),
    ok = ct_rpc:call(RouterNode2, blockchain_worker, submit_txn, [SignedSCOpenTxn2]),

    %% check that sc open txn appears on miners
    CheckTypeSCOpen = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_open_v1 end,
    CheckTxnSCOpen1 = fun(T) -> T == SignedSCOpenTxn1 end,
    CheckTxnSCOpen2 = fun(T) -> T == SignedSCOpenTxn2 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCOpen, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen1, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen2, timer:seconds(30)),

    %% check state_channels from both nodes appears on the ledger
    {ok, SC1} = get_ledger_state_channel(RouterNode1, ID1, RouterPubkeyBin1),
    {ok, SC2} = get_ledger_state_channel(RouterNode2, ID2, RouterPubkeyBin2),
    true = check_ledger_state_channel(SC1, RouterPubkeyBin1, ID1),
    true = check_ledger_state_channel(SC2, RouterPubkeyBin2, ID2),
    ct:pal("SC1: ~p", [SC1]),
    ct:pal("SC2: ~p", [SC2]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Payload1 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload2 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload3 = crypto:strong_rand_bytes(24+rand:uniform(23)),
    Payload4 = crypto:strong_rand_bytes(rand:uniform(23)),
    Payload5 = crypto:strong_rand_bytes(rand:uniform(23)),
    Packet1 = blockchain_helium_packet_v1:new({eui, DevEUI1, AppEUI1}, Payload1), %% pretend this is a join, it will go to both ouis
    Packet2 = blockchain_helium_packet_v1:new({devaddr, 1207959553}, Payload2), %% pretend this is a packet after join, only routes to oui 1
    Packet3 = blockchain_helium_packet_v1:new({devaddr, 1207959562}, Payload3), %% pretend this is a packet after join, only routes to oui 2
    Packet4 = blockchain_helium_packet_v1:new({eui, DevEUI2, AppEUI2}, Payload4), %% pretend this is a join, it will go to oui 2
    Packet5 = blockchain_helium_packet_v1:new({eui, DevEUI3, AppEUI3}, Payload5), %% pretend this is a join, it will go to nobody
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet3, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet4, []]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet5, []]),

    %% wait ExpireWithin + 10 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 10),

    %% wait for the state_channel_close for sc open1 txn to appear
    CheckSCClose1 = fun(T) ->
                            blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 andalso
                            blockchain_state_channel_v1:id(blockchain_txn_state_channel_close_v1:state_channel(T)) == blockchain_ledger_state_channel_v1:id(SC1)
                    end,

    %% wait for the state_channel_close for sc open2 txn to appear
    CheckSCClose2 = fun(T) ->
                            blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 andalso
                            blockchain_state_channel_v1:id(blockchain_txn_state_channel_close_v1:state_channel(T)) == blockchain_ledger_state_channel_v1:id(SC2)
                    end,

    ok = miner_ct_utils:wait_for_txn(Miners, CheckSCClose1, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckSCClose2, timer:seconds(30)),

    %% check state_channel is removed once the close txn appears
    {error, not_found} = get_ledger_state_channel(RouterNode1, ID1, RouterPubkeyBin1),
    {error, not_found} = get_ledger_state_channel(RouterNode2, ID2, RouterPubkeyBin2),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode1, CheckSCClose1),
    SCCloseTxn1 = miner_ct_utils:get_txn(BlockDetails, CheckSCClose1),
    SCCloseTxn2 = miner_ct_utils:get_txn(BlockDetails, CheckSCClose2),
    ct:pal("SCCloseTxn1: ~p", [SCCloseTxn1]),
    ct:pal("SCCloseTxn2: ~p", [SCCloseTxn2]),

    %% find the block that this SC opened in, we need the hash
    [{OpenHash1, _}] = miner_ct_utils:get_txn_block_details(RouterNode1, CheckTxnSCOpen1),
    [{OpenHash2, _}] = miner_ct_utils:get_txn_block_details(RouterNode2, CheckTxnSCOpen2),

    %% construct what the skewed merkle tree should look like for the first state channel
    ExpectedTree = skewed:add(Payload2, skewed:add(Payload1, skewed:new(OpenHash1))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn1)), skewed:root_hash(ExpectedTree)),

    %% construct what the skewed merkle tree should look like for the second state channel
    ExpectedTree2 = skewed:add(Payload4, skewed:add(Payload3, skewed:add(Payload1, skewed:new(OpenHash2)))),
    %% assert the root hashes should match
    ?assertEqual(blockchain_state_channel_v1:root_hash(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn2)), skewed:root_hash(ExpectedTree2)),

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn1, ClientNodePubkeyBin, 2),
    true = check_sc_num_dcs(SCCloseTxn1, ClientNodePubkeyBin, 3),

    true = check_sc_num_packets(SCCloseTxn2, ClientNodePubkeyBin, 3),
    true = check_sc_num_dcs(SCCloseTxn2, ClientNodePubkeyBin, 4),

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
