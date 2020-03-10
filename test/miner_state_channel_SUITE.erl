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
         multi_clients_packets_expiry_test/1
        ]).

%% common test callbacks

all() -> [
          no_packets_expiry_test,
          packets_expiry_test,
          multi_clients_packets_expiry_test
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
                                                   ?dkg_curve => Curve,
                                                   ?max_payments => 10}),

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

    [   {consensus_miners, ConsensusMiners},
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

    %% check that oui txn appears on miners
    CheckTypeOUI = fun(T) -> blockchain_txn:type(T) == blockchain_txn_oui_v1 end,
    CheckTxnOUI = fun(T) -> T == SignedOUITxn end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeOUI, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnOUI, timer:seconds(30)),

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

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(30)),
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTxnSCOpen, timer:seconds(30)),

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

    %% At this point, we're certain that sc is open
    %% Use client node to send some packets
    Packet1 = blockchain_helium_packet_v1:new(OUI, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new(OUI, <<"p2">>),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet1]),
    ok = ct_rpc:call(ClientNode, blockchain_state_channels_client, packet, [Packet2]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(30)),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_ct_utils:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),
    ?assertEqual(1,
                 length(blockchain_state_channel_v1:balances(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)))),

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

    %% At this point, we're certain that sc is open
    %% Use client nodes to send some packets
    Packet1 = blockchain_helium_packet_v1:new(OUI, <<"p1">>),
    Packet2 = blockchain_helium_packet_v1:new(OUI, <<"p2">>),
    Packet3 = blockchain_helium_packet_v1:new(OUI, <<"p3">>),
    Packet4 = blockchain_helium_packet_v1:new(OUI, <<"p4">>),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet1]),
    ok = ct_rpc:call(ClientNode1, blockchain_state_channels_client, packet, [Packet2]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet3]),
    ok = ct_rpc:call(ClientNode2, blockchain_state_channels_client, packet, [Packet4]),

    %% wait ExpireWithin + 3 more blocks to be safe
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + ExpireWithin + 3, all, 100),
    %% for the state_channel_close txn to appear
    CheckTypeSCClose = fun(T) -> blockchain_txn:type(T) == blockchain_txn_state_channel_close_v1 end,
    ok = miner_ct_utils:wait_for_txn(Miners, CheckTypeSCClose, timer:seconds(60)),

    %% Check whether the balances are updated in the eventual sc close txn
    BlockDetails = miner_ct_utils:get_txn_block_details(RouterNode, CheckTypeSCClose),
    SCCloseTxn = miner_ct_utils:get_txn(BlockDetails, CheckTypeSCClose),
    ct:pal("SCCloseTxn: ~p", [SCCloseTxn]),
    ?assertEqual(2,
                 length(blockchain_state_channel_v1:balances(blockchain_txn_state_channel_close_v1:state_channel(SCCloseTxn)))),

    ok.
