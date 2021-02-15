-module(miner_grpc_state_channel_apis_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_state_channel_close_v1_pb.hrl").
-include("miner_ct_macros.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec),tl(tuple_to_list(Ref))))).

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
         is_valid_sc_test/1,
         close_sc_test/1,
         follow_multi_scs_test/1
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
    [
        is_valid_sc_test,
        close_sc_test,
        follow_multi_scs_test
    ].

scv2_only_tests() ->
    [
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

    DKGResults = miner_ct_utils:initial_dkg(Miners,
                                            AllVars ++ InitialPaymentTransactions ++ AddGwTxns ++ InitialDCTxns ++ [InitialPriceTxn],
                                            Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

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
        follow_multi_scs_test ->
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
     | Config].

end_per_testcase(TestCase, Config) ->
    ok = block_listener:stop(),
    miner_ct_utils:end_per_testcase(TestCase, Config),
    ct:pal("fin").


is_valid_sc_test(Config) ->
    {RouterNode, RouterPubkeyBin, _RouterSigFun} = ?config(router_node, Config),

    %% open state channel 1
    ExpireWithin = 8,
    Amount = 10,
    ID1 = open_state_channel(Config, ExpireWithin, Amount),

    %% check state_channels from both nodes appears on the ledger
    {ok, SC1} = get_ledger_state_channel(RouterNode, ID1, RouterPubkeyBin),
    true = check_ledger_state_channel(SC1, RouterPubkeyBin, ID1, Config),
    true = miner_ct_utils:wait_until(
             fun() ->
                     undefined /= ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, [])
             end),
    ct:pal("SC1: ~p", [SC1]),

    %% Wait till client has an active sc
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
                     ct:pal("TempID: ~p", [TempID]),
                     TempID /= undefined
             end,
             60, 500),

    ActiveSCID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    ct:pal("ActiveSCID: ~p", [ActiveSCID]),

    %% pull the active SC from the router node, confirm it has same ID as one from ledger
    %% and then use it to test the is_valid GRPC api
    ActiveSCPB = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),

    %% convert state channel record to map, grpc client only uses maps
    ActiveSCMap = ?record_to_map(blockchain_state_channel_v1_pb, ActiveSCPB),

    %% establish our GRPC connection
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    %% use the grpc APIs to confirm the state channel is valid/sane
    {ok, #{headers := Headers, result := #{msg := {is_valid_resp, ResponseMsg}, height := _ResponseHeight, signature := _ResponseSig} = Result}} = grpc_client:unary(
        Connection,
        #{sc => ActiveSCMap},
        'helium.gateway_state_channels',
        'is_valid',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg#{sc_id := ActiveSCID, valid := true, reason := <<>>}, ResponseMsg),

    ok.


close_sc_test(Config) ->
    %% open a SC and then submit a close
    {RouterNode, RouterPubkeyBin, _RouterSigFun} = ?config(router_node, Config),

    %% open state channel 1
    ExpireWithin = 8,
    Amount = 10,
    ID1 = open_state_channel(Config, ExpireWithin, Amount),

    %% check state_channels from both nodes appears on the ledger
    {ok, SC1} = get_ledger_state_channel(RouterNode, ID1, RouterPubkeyBin),
    true = check_ledger_state_channel(SC1, RouterPubkeyBin, ID1, Config),
    true = miner_ct_utils:wait_until(
             fun() ->
                     undefined /= ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, [])
             end),
    ct:pal("SC1: ~p", [SC1]),

    %% Wait till client has an active sc
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
                     ct:pal("TempID: ~p", [TempID]),
                     TempID /= undefined
             end,
             60, 500),

    ActiveSCID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    ct:pal("ActiveSCID: ~p", [ActiveSCID]),

    %% pull the active SC from the router node, we will need it in for our close txn
    ActiveSCPB = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),


    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),

    %% setup the close txn, first as records
    SC2 = blockchain_state_channel_v1:state(closed, ActiveSCPB),
    SignedSC2 = blockchain_state_channel_v1:sign(SC2, SigFun),
    Txn = blockchain_txn_state_channel_close_v1:new(SignedSC2, PubKeyBin),
    SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, SigFun),

    %% convert the records to maps ( current grpc client only supports maps )
    SignedSC2Map = ?record_to_map(blockchain_state_channel_v1_pb, SignedSC2),
    SignedTxnMap = ?record_to_map(blockchain_txn_state_channel_close_v1_pb, SignedTxn),
    SignedTxnMap2 = SignedTxnMap#{state_channel := SignedSC2Map},

    %% establish our GRPC connection
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    %% use the grpc APIs to confirm the state channel is valid/sane
    {ok, #{headers := Headers, result := #{msg := {close_resp, ResponseMsg}, height := _ResponseHeight, signature := _ResponseSig} = Result}} = grpc_client:unary(
        Connection,
        #{close_txn => SignedTxnMap2},
        'helium.gateway_state_channels',
        'close',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg#{sc_id := ActiveSCID, response := <<"ok">>}, ResponseMsg),

    receive
        {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
            ct:pal("close height ~p", [CHT]),
            CloseTxn
    after timer:seconds(30) ->
            error(sc_close_timeout),
            unreachable
    end,

    ok.


follow_multi_scs_test(Config) ->
    %% setup 2 state channels and follow each, confirm we get expected streamed msgs for each
    Miners = ?config(miners, Config),
    [RouterNode1, RouterNode2 | _] = Miners,

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
    ct:pal("RouterNode: ~p", [RouterNode1]),
    ok = ct_rpc:call(RouterNode1, blockchain_worker, submit_txn, [SignedOUITxn1]),
    receive
        {blockchain_txn_oui_v1, _, _} ->
            ok;
        Other ->
            error({bad_txn, Other})
    after timer:seconds(55) ->
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
    ExpireWithin = 8,
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
                     undefined /= ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_id, []) andalso
                         undefined /= ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_id, [])
             end),
    ct:pal("SC1: ~p", [SC1]),
    ct:pal("SC2: ~p", [SC2]),

    %% Wait till client has an active sc
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID = ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_id, []),
                     ct:pal("TempID: ~p", [TempID]),
                     TempID /= undefined
             end,
             60, 500),

    ActiveSCID = ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc_id, []),
    ct:pal("ActiveSCID: ~p", [ActiveSCID]),

    %% pull the active SC from the router node, confirm it has same ID as one from ledger
    %% and then use it to test the is_valid GRPC api
    ActiveSCPB = ct_rpc:call(RouterNode1, blockchain_state_channels_server, active_sc, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),

    %% establish our GRPC connection
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 8080),

    %% setup a 'follow' streamed connection to server
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway_state_channels',
        follow,
        gateway_client_pb
    ),
    ct:pal("follow stream ~p:", [Stream]),

    %% setup the follows for the two SCs
    LedgerSCMod = ledger_sc_mod(Config),
    ok = grpc_client:send(Stream, #{sc_id => ID1, owner => LedgerSCMod:owner(SC1)}),
    ok = grpc_client:send(Stream, #{sc_id => ID2, owner => LedgerSCMod:owner(SC2)}),

    %% wait until we see a close txn for SC1
    % and then check we were streamed the expected follow msgs
    _SCCloseTxn1 =
        receive
            {blockchain_txn_state_channel_close_v1, CHT, CloseTxn} ->
                ct:pal("close height ~p", [CHT]),
                CloseTxn;
            Other3 ->
                ct:pal("Other3: ~p", [Other3]),
                error({bad_txn, Other3}),
                unreachable
        after timer:seconds(30) ->
                error(sc_close_timeout),
                unreachable
    end,
    ct:pal("SCCloseTxn1: ~p", [_SCCloseTxn1]),

    %% headers are always sent with the first data msg
    {headers, Headers0} = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Headers0: ~p", [Headers0]),
    #{<<":status">> := Headers0HttpStatus} = Headers0,
    ?assertEqual(Headers0HttpStatus, <<"200">>),

    %% we should receive 3 stream msgs for SC1, closable, closing and closed
    {data, #{height := _Data0Height, msg := {follow_streamed_msg, Data0FollowMsg}}} = Data0 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data0: ~p", [Data0]),
    #{sc_id := Data0SCID1, close_state := Data0CloseState} = Data0FollowMsg,
    ?assertEqual(ActiveSCID, Data0SCID1),
    ?assertEqual(closable, Data0CloseState),

    {data, #{height := _Data1Height, msg := {follow_streamed_msg, Data1FollowMsg}}} = Data1 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data1: ~p", [Data1]),
    #{sc_id := Data1SCID1, close_state := Data1CloseState} = Data1FollowMsg,
    ?assertEqual(ActiveSCID, Data1SCID1),
    ?assertEqual(closing, Data1CloseState),

    {data, #{height := _Data2Height, msg := {follow_streamed_msg, Data2FollowMsg}}} = Data2 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data2: ~p", [Data2]),
    #{sc_id := Data2SCID1, close_state := Data2CloseState} = Data2FollowMsg,
    ?assertEqual(ActiveSCID, Data2SCID1),
    ?assertEqual(closed, Data2CloseState),

    %% SC1 has now closed to lets check SC2
    true = miner_ct_utils:wait_until(
             fun() ->
                     TempID2 = ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_id, []),
                     ct:pal("TempID2: ~p", [TempID2]),
                     TempID2 /= undefined
             end,
             60, 500),

    ActiveSCID2 = ct_rpc:call(RouterNode2, blockchain_state_channels_server, active_sc_id, []),
    ct:pal("ActiveSCID2: ~p", [ActiveSCID2]),

    %% check that the ids differ, make sure we have a new SC
    ?assertNotEqual(ActiveSCID, ActiveSCID2),

    %% wait until we see a close txn for SC2 and then assert the streamed msgs received for it
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

    %% assert the streamed msgs for SC2
    {data, #{height := _Data3Height, msg := {follow_streamed_msg, Data3FollowMsg}}} = Data3 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data3: ~p", [Data3]),
    #{sc_id := Data3SCID2, close_state := Data3CloseState} = Data3FollowMsg,
    ?assertEqual(ActiveSCID2, Data3SCID2),
    ?assertEqual(Data3CloseState, closable),

    {data, #{height := _Data4Height, msg := {follow_streamed_msg, Data4FollowMsg}}} = Data4 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data4: ~p", [Data4]),
    #{sc_id := Data4SCID2, close_state := Data4CloseState} = Data4FollowMsg,
    ?assertEqual(ActiveSCID2, Data4SCID2),
    ?assertEqual(Data4CloseState, closing),

    {data, #{height := _Data5Height, msg := {follow_streamed_msg, Data5FollowMsg}}} = Data5 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data5: ~p", [Data5]),
    #{sc_id := Data5SCID2, close_state := Data5CloseState} = Data5FollowMsg,
    ?assertEqual(ActiveSCID2, Data5SCID2),
    ?assertEqual(Data5CloseState, closed),

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
                     undefined /= ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, [])
             end),
    HeightPrint2 = miner_ct_utils:height(RouterNode),
    ct:pal("State channel active at ~p", [HeightPrint2]),

    ct:pal("SC: ~p", [SC]),
    ID.


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


ledger_sc_mod(Config) ->
    case ?config(sc_version, Config) of
        1 -> blockchain_ledger_state_channel_v1;
        2 -> blockchain_ledger_state_channel_v2
    end.


reward_vars() ->
    %% Taken from the chain at height: 534504
    #{ consensus_percent => 0.06,
       dc_percent => 0.325,
       poc_challengees_percent => 0.18,
       poc_challengers_percent => 0.0095,
       poc_witnesses_percent => 0.0855,
       securities_percent => 0.34
     }.
