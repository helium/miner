-module(miner_gateway_mux_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    init_per_suite/1,
    end_per_suite/1,
    all/0
]).

-export([gateway_signing_test/1, mux_packet_routing/1]).

all() ->
    [gateway_signing_test, mux_packet_routing].

init_per_suite(Config) ->
    ok = application:set_env(miner, gateway_and_mux_enable, true),
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

mux_packet_routing(Config) ->
    BaseDir = ?config(base_dir, Config),
    Ledger = blockchain_ledger_v1:new(BaseDir),

    application:ensure_all_started(meck),
    Parent = self(),
    meck:new(miner_lora, [passthrough]),
    meck:expect(miner_lora, route, fun(Packet) ->
        ct:pal("Received packet from the mux: ~p", [Packet]),
        case longfi:deserialize(Packet) of
            {ok, LongfiPacket} ->
                case is_onion_packet(LongfiPacket) of
                    true ->
                        Parent ! {packet_received, longfi_routed};
                    false ->
                        Parent ! {packet_received, lora_skipped}
                end;
            error ->
                Parent ! {packet_received, udp_skipped}
        end,
        {noop, non_longfi}
    end),
    ?assert(is_pid(whereis(miner_mux_port))),

    {ok, RadioPid} = miner_fake_radio_backplane:start_link(11, 6666, [{1680, 16#821fb7fffffffff}]),

    ok = miner_fake_radio_backplane:transmit(<<"hello">>, 915.5, 16#821fb7fffffffff),

    receive
        {packet_received, PacketType} -> ?assert(PacketType =:= udp_skipped)
    after 2000 ->
        ct:fail("no packets received")
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
        ct:fail("no packets received")
    end,

    Lora = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(ack, 0, 1, 0, Onion, #{})),
    ok = miner_fake_radio_backplane:transmit(Lora, 915.5, 16#821fb7fffffffff),

    receive
        {packet_received, PacketType3} -> ?assert(PacketType3 =:= lora_skipped)
    after 2000 ->
        ct:fail("no packets received")
    end,

    gen_server:stop(RadioPid),
    meck:unload(miner_lora),
    ok.

is_onion_packet(Packet) ->
    longfi:type(Packet) == monolithic andalso longfi:oui(Packet) == 0 andalso longfi:device_id(Packet) == 1.
