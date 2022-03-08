%%% RELOC KEEP - net layer
-module(miner_router_SUITE).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    all/0
]).

%% State channel packet handler callback
-export([handle_packet/2]).

-export([
    basic/1,
    default_routers/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("miner_ct_macros.hrl").
-include("lora.hrl").

-define(SFLOCS, [631210968910285823, 631210968909003263, 631210968912894463, 631210968907949567]).
-define(NYLOCS, [631243922668565503, 631243922671147007, 631243922895615999, 631243922665907711]).

handle_packet(Packet, Pid) ->
    ct:pal("Got SC packet ~p", [Packet]),
    ct_sc_handler ! {sc_handler, Packet, Pid},
    ok.

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() -> [basic, default_routers].

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    MinersAndPorts = ?config(ports, Config),
    Addresses = ?config(addresses, Config),
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    InitialDCTransactions = [ blockchain_txn_dc_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    %AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, h3:from_geo({37.780586, -122.469470}, 13), 0)
                 %|| Addr <- Addresses],

    Locations = ?SFLOCS ++ ?NYLOCS,
    AddressesWithLocations = lists:zip(Addresses, Locations),
    InitialGenGatewayTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- AddressesWithLocations],


    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = ?config(block_time, Config),
    Interval = ?config(election_interval, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),
    %% VarCommitInterval = ?config(var_commit_interval, Config),

    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialVars ++ InitialPaymentTransactions ++ InitialDCTransactions ++ InitialGenGatewayTxns,
                                             Addresses, NumConsensusMembers, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    RadioPorts = [ P || {_Miner, {_TP, P}} <- MinersAndPorts ],
    miner_fake_radio_backplane:start_link(8, 45000, lists:zip(RadioPorts, Locations)),

    %% confirm height has grown to 1
    ok = miner_ct_utils:wait_for_gte(height, Miners, 2),

    miner_fake_radio_backplane ! go,

    meck:new(blockchain_state_channels_server, [passthrough]),
    meck:expect(blockchain_state_channels_server, packet, fun(Packet, HandlerPid) -> handle_packet(Packet, HandlerPid) end),

    application:ensure_all_started(throttle),
    application:ensure_all_started(ranch),
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),
    application:set_env(blockchain, sc_packet_handler, ?MODULE),

    lists:foreach(fun(Miner) ->
                          ct_rpc:call(Miner, application, set_env, [miner, default_routers, []])
                  end, Miners),

    SwarmOpts = [{libp2p_nat, [{enabled, false}]}],
    {ok, RouterSwarm} = libp2p_swarm:start(router_swarm, SwarmOpts),

    [{swarm, RouterSwarm}|Config]
    catch
        What:Why ->
            end_per_testcase(_TestCase, Config),
            erlang:What(Why)
    end.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config),
    case proplists:get_value(swarm, Config) of
        undefined ->
            ok;
        RouterSwarm ->
            libp2p_swarm:stop(RouterSwarm)
    end,
    gen_server:stop(miner_fake_radio_backplane),
    meck:unload(blockchain_state_channels_server),
    ok.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(Config) ->
    Miners = ?config(miners, Config),
    RouterSwarm = ?config(swarm, Config),
    [Owner| _Tail] = Miners,
    OwnerPubKeyBin = ct_rpc:call(Owner, blockchain_swarm, pubkey_bin, []),

    register(ct_sc_handler, self()),

    ok = libp2p_swarm:listen(RouterSwarm, "/ip4/0.0.0.0/tcp/0"),
    RouterPubkey = libp2p_swarm:pubkey_bin(RouterSwarm),
    _Version = simple_http_stream_test:version(),
    ok = libp2p_swarm:add_stream_handler(
        RouterSwarm,
        ?STATE_CHANNEL_PROTOCOL_V1,
        {libp2p_framed_stream, server, [blockchain_state_channel_handler]}
    ),

    [RouterAddress|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    OwnerSwarm = ct_rpc:call(Owner, blockchain_swarm, swarm, []),
    {ok, _} = ct_rpc:call(Owner, libp2p_swarm, connect, [OwnerSwarm, RouterAddress]),

    [begin
         MinerSwarm = ct_rpc:call(Miner, blockchain_swarm, swarm, []),
         {ok, _} = ct_rpc:call(Miner, libp2p_swarm, connect, [MinerSwarm, RouterAddress])
     end || Miner <- Miners],

    DevEUI=rand:uniform(trunc(math:pow(2, 64))),
    AppEUI=rand:uniform(trunc(math:pow(2, 64))),

    ct:pal("Owner is ~p", [Owner]),
    ct:pal("MARKER ~p", [{OwnerPubKeyBin, RouterPubkey}]),
    {Filter, _} = xor16:to_bin(xor16:new([<<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>], fun xxhash:hash64/1)),
    OUI = 1,
    Txn = ct_rpc:call(Owner, blockchain_txn_oui_v1, new, [OUI, OwnerPubKeyBin, [RouterPubkey], Filter, 8]),
    {ok, Pubkey, SigFun, _ECDHFun} = ct_rpc:call(Owner, blockchain_swarm, keys, []),
    SignedTxn = ct_rpc:call(Owner, blockchain_txn_oui_v1, sign, [Txn, SigFun]),
    ok = ct_rpc:call(Owner, blockchain_worker, submit_txn, [SignedTxn]),

    Chain = ct_rpc:call(Owner, blockchain_worker, blockchain, []),
    Ledger = blockchain:ledger(Chain),

    ?assertAsync(begin
                        Result =
                            case ct_rpc:call(Owner, blockchain_ledger_v1, find_routing, [1, Ledger]) of
                                {ok, Routing} ->
                                    ct:pal("Routing ~p", [Routing]),
                                    true;
                                _ -> false
                            end
                 end,
        Result == true, 60, timer:seconds(1)),

    Packet = <<?JOIN_REQUEST:3, 0:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little, 1111:16/integer-unsigned-big, 0:32/integer-unsigned-big>>,
    miner_fake_radio_backplane:transmit(Packet, 911.200, 631210968910285823),

    ReplyPayload = crypto:strong_rand_bytes(12),

    ct:pal("SENT ~p", [Packet]),
    receive
        {sc_handler, Thing, HandlerPid} ->
            PubKeyBin = libp2p_crypto:pubkey_to_bin(Pubkey),
            ct:pal("Thing ~p", [Thing]),
            ?assert(blockchain_state_channel_packet_v1:validate(Thing)),
            ?assertEqual(PubKeyBin, blockchain_state_channel_packet_v1:hotspot(Thing)),
            HeliumPacket = blockchain_state_channel_packet_v1:packet(Thing),
            ?assertEqual({eui, DevEUI, AppEUI}, blockchain_helium_packet_v1:routing_info(HeliumPacket)),
            ?assertEqual(Packet, blockchain_helium_packet_v1:payload(HeliumPacket)),
            Resp = blockchain_state_channel_response_v1:new(true,
                                                            blockchain_helium_packet_v1:new_downlink(ReplyPayload,
                                                                                                     erlang:system_time(millisecond) + 1000,
                                                                                                     28, 911.6, <<"SF8BW500">>)),
            miner_fake_radio_backplane:get_next_packet(),
            blockchain_state_channel_handler:send_response(HandlerPid, Resp),
            ok;
        _Other ->
            ct:pal("wrong data ~p", [_Other]),
            ct:fail(wrong_data)
    after 2000 ->
        ct:fail(send_timeout)
    end,

    receive
        {fake_radio_backplane, RespPacket} ->
            ct:pal("got downlink response packet ~p", [RespPacket]),
            ?assertEqual(ReplyPayload, base64:decode(maps:get(<<"data">>, RespPacket)))
    after 2000 ->
        ct:fail(backplane_timeout)
    end,

    miner_fake_radio_backplane:transmit(Packet, 911.200, 631210968910285823),
    ok.

default_routers(Config) ->
    Miners = ?config(miners, Config),
    RouterSwarm = ?config(swarm, Config),
    [Owner| _Tail] = Miners,
    OwnerPubKeyBin = ct_rpc:call(Owner, blockchain_swarm, pubkey_bin, []),

    register(ct_sc_handler, self()),

    ok = libp2p_swarm:listen(RouterSwarm, "/ip4/0.0.0.0/tcp/0"),
    RouterPubkey = libp2p_swarm:pubkey_bin(RouterSwarm),
    _Version = simple_http_stream_test:version(),
    ok = libp2p_swarm:add_stream_handler(
        RouterSwarm,
        ?STATE_CHANNEL_PROTOCOL_V1,
        {libp2p_framed_stream, server, [blockchain_state_channel_handler]}
    ),

    lists:foreach(fun(Miner) ->
                          ct_rpc:call(Miner, application, set_env, [miner, default_routers, [libp2p_crypto:pubkey_bin_to_p2p(RouterPubkey)]])
                  end, Miners),

    [RouterAddress|_] = libp2p_swarm:listen_addrs(RouterSwarm),
    OwnerSwarm = ct_rpc:call(Owner, blockchain_swarm, swarm, []),
    {ok, _} = ct_rpc:call(Owner, libp2p_swarm, connect, [OwnerSwarm, RouterAddress]),

    DevEUI=rand:uniform(trunc(math:pow(2, 64))),
    AppEUI=rand:uniform(trunc(math:pow(2, 64))),

    ct:pal("Owner is ~p", [Owner]),
    ct:pal("MARKER ~p", [{OwnerPubKeyBin, RouterPubkey}]),
    {ok, Pubkey, _SigFun, _ECDHFun} = ct_rpc:call(Owner, blockchain_swarm, keys, []),

    Packet = <<?JOIN_REQUEST:3, 0:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little, 1111:16/integer-unsigned-big, 0:32/integer-unsigned-big>>,
    miner_fake_radio_backplane:transmit(Packet, 911.200, 631210968910285823),

    ReplyPayload = crypto:strong_rand_bytes(12),

    ct:pal("SENT ~p", [Packet]),
    receive
        {sc_handler, Thing, HandlerPid} ->
            PubKeyBin = libp2p_crypto:pubkey_to_bin(Pubkey),
            ct:pal("Thing ~p", [Thing]),
            ?assert(blockchain_state_channel_packet_v1:validate(Thing)),
            ?assertEqual(PubKeyBin, blockchain_state_channel_packet_v1:hotspot(Thing)),
            HeliumPacket = blockchain_state_channel_packet_v1:packet(Thing),
            ?assertEqual({eui, DevEUI, AppEUI}, blockchain_helium_packet_v1:routing_info(HeliumPacket)),
            ?assertEqual(Packet, blockchain_helium_packet_v1:payload(HeliumPacket)),
            Resp = blockchain_state_channel_response_v1:new(true,
                                                            blockchain_helium_packet_v1:new_downlink(ReplyPayload,
                                                                                                     erlang:system_time(millisecond) + 1000,
                                                                                                     28, 911.6, <<"SF8BW500">>)),
            miner_fake_radio_backplane:get_next_packet(),
            blockchain_state_channel_handler:send_response(HandlerPid, Resp),
            ok;
        _Other ->
            ct:pal("wrong data ~p", [_Other]),
            ct:fail(wrong_data)
    after 2000 ->
        ct:fail(send_timeout)
    end,

    receive
        {fake_radio_backplane, RespPacket} ->
            ct:pal("got downlink response packet ~p", [RespPacket]),
            ?assertEqual(ReplyPayload, base64:decode(maps:get(<<"data">>, RespPacket)))
    after 2000 ->
        ct:fail(backplane_timeout)
    end,
    miner_fake_radio_backplane:transmit(Packet, 911.200, 631210968910285823),
    ok.
