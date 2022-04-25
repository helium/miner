-module(miner_gateway_mux_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    init_per_suite/1,
    end_per_suite/1,
    all/0
]).

-export([gateway_signing_test/1, gateway_grpc_reconnect_test/1, mux_packet_routing_light/1]).

all() ->
    [gateway_signing_test, gateway_grpc_reconnect_test, mux_packet_routing_light].

init_per_suite(Config) ->
    ok = application:load(miner),
    ok = application:set_env(miner, gateway_and_mux_enable, true),
    ok = application:set_env(miner, radio_device, {{127, 0, 0, 1}, 1680, deprecated, deprecated}),
    ok = application:set_env(miner, gateways_run_chain, false),
    ok = application:set_env(miner, mode, gateway),
    application:ensure_all_started(miner),
    Config.

end_per_suite(Config) ->
    application:stop(miner),
    Config.

gateway_signing_test(_Config) ->
    {ok, BaseDir} = application:get_env(blockchain, base_dir),

    ?assert(is_pid(whereis(miner_gateway_port))),
    ?assert(is_pid(whereis(miner_gateway_ecc_worker))),

    {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
    ?assertMatch({ecc_compact, {#'ECPoint'{}, {namedCurve, {1, 2, 840, 10045, 3, 1, 7}}}}, PubKey),

    Binary = <<"go go gadget gateway">>,
    {ok, Signature} = miner_gateway_ecc_worker:sign(Binary),
    ?assert(libp2p_crypto:verify(Binary, Signature, PubKey)),

    {ok, PrivKeyBin} = file:read_file(
        filename:absname(filename:join([BaseDir, "miner", "gateway_swarm_key"]))
    ),
    #{secret := PrivKey} = libp2p_crypto:keys_from_bin(PrivKeyBin),
    VerifyFun = libp2p_crypto:mk_ecdh_fun(PrivKey),

    {ok, GatewayEcdhPreseed} = miner_gateway_ecc_worker:ecdh(PubKey),
    VerifyPreseed = VerifyFun(PubKey),

    ?assertEqual(GatewayEcdhPreseed, VerifyPreseed),
    ok.

gateway_grpc_reconnect_test(_Config) ->
    {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
    {state, #{http_connection := ConnectionPid}, _, _, _, _, _} = sys:get_state(miner_gateway_ecc_worker),

    true = erlang:exit(ConnectionPid, shutdown),

    timer:sleep(100),

    {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
    {state, #{http_connection := NewConnectionPid}, _, _, _, _, _} = sys:get_state(miner_gateway_ecc_worker),

    ?assert(is_process_alive(whereis(miner_gateway_ecc_worker))),
    ?assertNot(is_process_alive(ConnectionPid)),
    ?assert(is_process_alive(NewConnectionPid)),
    ok.

mux_packet_routing_light(Config) ->
    BaseDir = ?config(base_dir, Config),
    Ledger = blockchain_ledger_v1:new(BaseDir),

    application:ensure_all_started(meck),
    Parent = self(),
    meck:new(miner_lora_light, [passthrough]),
    meck:expect(miner_lora_light, route, fun(Packet) ->
        ct:pal("Received packet from the mux: ~p", [Packet]),
        case longfi:deserialize(Packet) of
            {ok, LongfiPacket} ->
                case is_onion_packet(LongfiPacket) of
                    true -> Parent ! {packet_received, longfi_routed};
                    false ->
                        case application:get_env(miner, gateway_and_mux_enable) of
                            {ok, true} ->
                                Parent ! {packet_received, lora_skipped},
                                %% on the first pass assume the gateway handles and drop the packet,
                                %% then flip the switch for miner to route on the next packet
                                ok = application:set_env(miner, gateway_and_mux_enable, false);
                            _ ->
                                Parent ! {packet_received, lora_routed},
                                %% on the second pass, reset back to the gateway handling routing
                                ok = application:set_env(miner, gateway_and_mux_enable, true)
                        end
                end;
            error ->
                Parent ! {packet_received, udp_skipped}
        end,
        {noop, non_longfi}
    end),
    ?assert(is_pid(whereis(miner_mux_port))),

    miner_lora_light:region_params_update(region_us915, []),

    {ok, RadioPid} = miner_fake_radio_backplane:start_link(11, 6666, [{1680, 16#821fb7fffffffff}]),
    ok = miner_fake_radio_backplane:transmit(<<"hello">>, 915.5, 16#821fb7fffffffff),

    receive
        {packet_received, PacketType} -> ?assert(PacketType =:= udp_skipped)
    after 2000 ->
        ct:fail("no udp packets received")
    end,

    BlockHash = crypto:strong_rand_bytes(32),

    #{public := PubKey1} = libp2p_crypto:generate_keys(ecc_compact),
    #{public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    #{public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),

    Data1 = <<1, 2>>,
    Data2 = <<3, 4>>,
    Data3 = <<5, 6>>,
    OnionKey = libp2p_crypto:generate_keys(ecc_compact),
    {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, [{PubKey1, Data1}, {PubKey2, Data2}, {PubKey3, Data3}], BlockHash, Ledger),
    ct:pal("onion packet constructed ~p", [Onion]),

    Longfi = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(monolithic, 0, 1, 0, Onion, #{})),
    ok = miner_fake_radio_backplane:transmit(Longfi, 915.5, 16#821fb7fffffffff),

    receive
        {packet_received, PacketType2} -> ?assert(PacketType2 =:= longfi_routed)
    after 2000 ->
        ct:fail("no poc packets received")
    end,

    Lora = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(ack, 0, 1, 0, Onion, #{})),
    ok = miner_fake_radio_backplane:transmit(Lora, 915.5, 16#821fb7fffffffff),

    receive
        {packet_received, PacketType3} -> ?assert(PacketType3 =:= lora_skipped)
    after 2000 ->
        ct:fail("no lora packets received")
    end,

    ok = miner_fake_radio_backplane:transmit(Lora, 915.5, 16#821fb7fffffffff),

    receive
        {packet_receive, PacketType4} -> ?assert(PacketType4 =:= lora_routed)
    after 2000 ->
        ct:fail("no lora packets received")
    end,

    gen_server:stop(RadioPid),
    meck:unload(miner_lora_light),
    ok.

is_onion_packet(Packet) ->
    longfi:type(Packet) == monolithic andalso longfi:oui(Packet) == 0 andalso longfi:device_id(Packet) == 1.
