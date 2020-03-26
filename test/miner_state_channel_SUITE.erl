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
         not_enough_dc_test/1,
         replay_test/1
        ]).

%% common test callbacks

all() -> [
          no_packets_expiry_test,
          packets_expiry_test,
          multi_clients_packets_expiry_test,
          not_enough_dc_test,
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
    %% VarCommitInterval = ?config(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   %% rule out rewards
                                                   ?election_interval => infinity,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

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
     {non_consensus_miners, NonConsensusMiners}
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

    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [erlang:list_to_binary(RouterP2PAddress)], 1, 1, 0]),
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
    TotalDC = 10,
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 11,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, TotalDC, ExpireWithin, 1]),
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
    true = check_ledger_state_channel(SC, RouterPubkeyBin, TotalDC, ID),
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
    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [erlang:list_to_binary(RouterP2PAddress)], OUI, 1, 0]),
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
    TotalDC = 10,
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, TotalDC, ExpireWithin, 1]),
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
    true = check_ledger_state_channel(SC, RouterPubkeyBin, TotalDC, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Packet1 = blockchain_helium_packet_v1:new(OUI, <<"p1">>),
    PacketInfo1 = {Packet1, <<"devaddr">>, 1, <<"mic1">>},
    Packet2 = blockchain_helium_packet_v1:new(OUI, <<"p2">>),
    PacketInfo2 = {Packet2, <<"devaddr">>, 2, <<"mic2">>},
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [PacketInfo1]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [PacketInfo2]),

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

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 2),

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
    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [erlang:list_to_binary(RouterP2PAddress)], OUI, 1, 0]),
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
    TotalDC = 10,
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, TotalDC, ExpireWithin, 1]),
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
    Packet1 = blockchain_helium_packet_v1:new(OUI, <<"p1">>),
    PacketInfo1 = {Packet1, <<"devaddr1">>, 1, <<"mic1">>},
    Packet2 = blockchain_helium_packet_v1:new(OUI, <<"p2">>),
    PacketInfo2 = {Packet2, <<"devaddr1">>, 2, <<"mic2">>},
    Packet3 = blockchain_helium_packet_v1:new(OUI, <<"p3">>),
    PacketInfo3 = {Packet3, <<"devaddr2">>, 1, <<"mic3">>},
    Packet4 = blockchain_helium_packet_v1:new(OUI, <<"p4">>),
    PacketInfo4 = {Packet4, <<"devaddr2">>, 2, <<"mic4">>},
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [PacketInfo1]),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [PacketInfo2]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [PacketInfo3]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [PacketInfo4]),

    %% check state_channel appears on the ledger
    {ok, SC} = get_ledger_state_channel(RouterNode, ID, RouterPubkeyBin),
    true = check_ledger_state_channel(SC, RouterPubkeyBin, TotalDC, ID),
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

    %% Check whether clientnode balance is correct

    ClientNodePubkeyBin1 = ct_rpc:call(ClientNode1, blockchain_swarm, pubkey_bin, []),
    ClientNodePubkeyBin2 = ct_rpc:call(ClientNode2, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin1, 2),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin2, 2),

    ok.

not_enough_dc_test(Config) ->
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
    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [erlang:list_to_binary(RouterP2PAddress)], OUI, 1, 0]),
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
    TotalDC = 10,
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, TotalDC, ExpireWithin, 1]),
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
    true = check_ledger_state_channel(SC, RouterPubkeyBin, TotalDC, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% 1DC = 24 byte packet, the client node sends `TotalDC` such packets
    Packets = lists:map(fun(I) ->
                                {blockchain_helium_packet_v1:new(OUI, crypto:strong_rand_bytes(24)),
                                 <<"devaddr">>,
                                 I,
                                 <<"mic", I>>
                                }
                        end,
                        lists:seq(1, TotalDC)),

    ct:pal("Packets: ~p", [Packets]),

    %% And then tries to send another one. Expectation is that this one doesn't make it.
    ExtraPacket = {blockchain_helium_packet_v1:new(OUI, <<"notenoughcredits">>),
                   <<"devaddr">>, 1, <<"mic">>},

    ok = lists:foreach(fun(Packet) ->
                               ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet])
                       end,
                       Packets),

    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [ExtraPacket]),

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

    %% Check whether clientnode's balance is correct
    ClientNodePubkeyBin = ct_rpc:call(ClientNode, blockchain_swarm, pubkey_bin, []),
    true = check_sc_num_packets(SCCloseTxn, ClientNodePubkeyBin, 10),

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
    OUI = 1,
    OUITxn = ct_rpc:call(RouterNode,
                         blockchain_txn_oui_v1,
                         new,
                         [RouterPubkeyBin, [erlang:list_to_binary(RouterP2PAddress)], OUI, 1, 0]),
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
    TotalDC = 10,
    ID = crypto:strong_rand_bytes(32),
    ExpireWithin = 25,
    SCOpenNonce = 1,
    SCOpenTxn = ct_rpc:call(RouterNode,
                            blockchain_txn_state_channel_open_v1,
                            new,
                            [ID, RouterPubkeyBin, TotalDC, ExpireWithin, SCOpenNonce]),
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
    true = check_ledger_state_channel(SC, RouterPubkeyBin, TotalDC, ID),
    ct:pal("SC: ~p", [SC]),

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Packet1 = blockchain_helium_packet_v1:new(OUI, <<"p1">>),
    PacketInfo1 = {Packet1, <<"devaddr">>, 1, <<"mic1">>},
    Packet2 = blockchain_helium_packet_v1:new(OUI, <<"p2">>),
    PacketInfo2 = {Packet2, <<"devaddr">>, 2, <<"mic2">>},
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [PacketInfo1]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [PacketInfo2]),

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
    NewTotalDC = 10,
    NewID = crypto:strong_rand_bytes(32),
    NewExpireWithin = 5,
    NewSCOpenTxn = ct_rpc:call(RouterNode,
                               blockchain_txn_state_channel_open_v1,
                               new,
                               [NewID, RouterPubkeyBin, NewTotalDC, NewExpireWithin, SCOpenNonce]),

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

check_ledger_state_channel(LedgerSC, OwnerPubkeyBin, Amount, SCID) ->
    CheckId = SCID == blockchain_ledger_state_channel_v1:id(LedgerSC),
    CheckOwner = OwnerPubkeyBin == blockchain_ledger_state_channel_v1:owner(LedgerSC),
    CheckAmount = Amount == blockchain_ledger_state_channel_v1:amount(LedgerSC),
    CheckId andalso CheckOwner andalso CheckAmount.

print_hbbft_buf({ok, Txns}) ->
    [blockchain_txn:deserialize(T) || T <- Txns].

print_txn_mgr_buf(Txns) ->
    [{Txn, length(Accepts), length(Rejects)} || {Txn, {_Callback, Accepts, Rejects, _Dialers}} <- Txns].

check_sc_num_packets(SCCloseTxn, ClientPubkeyBin, ExpectedNumPackets) ->
    SC = blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn),
    NumPackets = blockchain_state_channel_v1:num_packets(SC, ClientPubkeyBin),
    ExpectedNumPackets == NumPackets.
