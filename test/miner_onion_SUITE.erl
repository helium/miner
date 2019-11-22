-module(miner_onion_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").
-include("ct_macros.hrl").

-export([
    all/0
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    application:ensure_all_started(lager),

    {ok, Sock} = gen_udp:open(0, [{active, false}, binary, {reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),

    #{secret := PrivateKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := PrivateKey2, public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := _PrivateKey3, public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey) end),

    {ok, Server} = miner_onion_server:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey)
    }),

    TestDir = miner_ct_utils:tmp_dir("miner_onion_suite_basic"),
    Ledger = blockchain_ledger_v1:new(TestDir),
    BlockHash = crypto:strong_rand_bytes(32),
    Data1 = <<1, 2, 3>>,
    Data2 = <<4, 5, 6>>,
    Data3 = <<7, 8, 9>>,
    OnionKey = #{public := OnionCompactKey} = libp2p_crypto:generate_keys(ecc_compact),

    % This is for `try_decrypt`
    meck:new(blockchain_worker, [passthrough]),
    meck:expect(blockchain_worker, blockchain, fun() -> ok end),
    meck:new(blockchain, [passthrough]),
    meck:expect(blockchain, ledger, fun(_) -> Ledger end),
    meck:new(blockchain_ledger_v1, [passthrough]),
    meck:expect(blockchain_ledger_v1, find_poc, fun(_, _) ->
        PoC = blockchain_ledger_poc_v2:new(<<"SecretHash">>, <<"OnionKeyHash">>, <<"Challenger">>, BlockHash),
        {ok, [PoC]}
    end),

    {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, [{PubKey, Data1},
                                                              {PubKey2, Data2},
                                                              {PubKey3, Data3}], BlockHash, Ledger),
    ct:pal("constructed onion ~p", [Onion]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt,  fun(Data0, OnionCompactKey0, Origin, _Time, _RSSI, _Stream) ->
        ?assertEqual(radio, Origin),
        ?assertEqual(Data1, Data0),
        ?assertEqual(libp2p_crypto:pubkey_to_bin(OnionCompactKey), OnionCompactKey0)
    end),

    Rx0 = #helium_LongFiRxPacket_pb{
        oui=0,
        device_id=1,
        crc_check=true,
        spreading= 'SF8',
        payload= Onion
    },
    Resp0 = #helium_LongFiResp_pb{id=0, kind={rx, Rx0}},
    Packet0 = helium_longfi_pb:encode_msg(Resp0, helium_LongFiResp_pb),
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, Packet0),
    {ok, {{127,0,0,1}, 5678, Packet1}} = gen_udp:recv(Sock, 0, 5000),

    Got0 = helium_longfi_pb:decode_msg(Packet1, helium_LongFiReq_pb),
    {_, Got0Uplink} = Got0#helium_LongFiReq_pb.kind,
    X = Got0Uplink#helium_LongFiTxPacket_pb.payload,

    timer:sleep(2000),
    %% check that the packet size is the same
    ?assertEqual(erlang:byte_size(Onion), erlang:byte_size(X)),
    gen_server:stop(Server),
    ct:pal("~p~n", [X]),

    ?assert(meck:validate(miner_onion_server)),
    meck:unload(miner_onion_server),
    ?assert(meck:validate(blockchain_swarm)),
    meck:unload(blockchain_swarm),

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey2) end),

    Parent = self(),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt, fun(Data0, OnionCompactKey0, Origin, _Time, _RSSI, _Stream) ->
        ?assertEqual(radio, Origin),
        Passed = Data2 == Data0 andalso libp2p_crypto:pubkey_to_bin(OnionCompactKey) == OnionCompactKey0,
        Parent ! {passed, Passed},
        ok
    end),

    {ok, Server1} = miner_onion_server:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey2)
    }),

    %% check we can't decrypt the original
    Rx2 = #helium_LongFiRxPacket_pb{
        oui=0,
        device_id=1,
        crc_check=true,
        spreading= 'SF8',
        payload= Onion
    },
    Resp2 = #helium_LongFiResp_pb{id=0, kind={rx, Rx2}},
    Packet2 = helium_longfi_pb:encode_msg(Resp2, helium_LongFiResp_pb),
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, Packet2),
    ?assertEqual({error, timeout}, gen_udp:recv(Sock, 0, 1000)),

    Rx3 = #helium_LongFiRxPacket_pb{
        oui = 0,
        device_id=1,
        crc_check=true,
        spreading= 'SF8',
        payload= X
    },
    Resp3 = #helium_LongFiResp_pb{id=0, kind={rx, Rx3}},
    Packet3 = helium_longfi_pb:encode_msg(Resp3, helium_LongFiResp_pb),
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, Packet3),
    {ok, {{127,0,0,1}, 5678, Packet4}} = gen_udp:recv(Sock, 0, 5000),


    Got1 = helium_longfi_pb:decode_msg(Packet4, helium_LongFiReq_pb),
    {_, Got1Uplink} = Got1#helium_LongFiReq_pb.kind,
    Y = Got1Uplink#helium_LongFiTxPacket_pb.payload,

    %% check we can't decrypt the next layer
    Rx5 = #helium_LongFiRxPacket_pb{
        oui=0,
        device_id=1,
        crc_check=true,
        spreading= 'SF8',
        payload= Y
    },
    Resp5 = #helium_LongFiResp_pb{id=0, kind={rx, Rx5}},
    Packet5 = helium_longfi_pb:encode_msg(Resp5, helium_LongFiResp_pb),
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, Packet5),
    ?assertEqual({error, timeout}, gen_udp:recv(Sock, 0, 1000)),

    ?assertEqual(erlang:byte_size(Onion), erlang:byte_size(Y)),

    receive
        {passed, true} -> ok;
        {passed, false} -> ct:fail("wrong data")
    after 2000 ->
        ct:fail("timeout")
    end,

    % ?assert(meck:validate(miner_onion_server)), we won't do this because of error timeout
    meck:unload(miner_onion_server),
    ?assert(meck:validate(blockchain_swarm)),
    meck:unload(blockchain_swarm),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
    gen_server:stop(Server1),
    ok.
