-module(miner_onion_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("pb/concentrate_pb.hrl").

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

    Data1 = <<1, 2, 3>>,
    Data2 = <<4, 5, 6>>,
    Data3 = <<7, 8, 9>>,
    OnionKey = #{public := OnionCompactKey} = libp2p_crypto:generate_keys(ecc_compact),
    {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, [{PubKey, Data1},
                                                              {PubKey2, Data2},
                                                              {PubKey3, Data3}]),
    ct:pal("constructed onion ~p", [Onion]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt,  fun(Data0, OnionCompactKey0, Origin, _Time, _RSSI, _Stream) ->
        ?assertEqual(radio, Origin),
        ?assertEqual(Data1, Data0),
        ?assertEqual(libp2p_crypto:pubkey_to_bin(OnionCompactKey), OnionCompactKey0)
    end),

    ok = gen_udp:send(Sock, "127.0.0.1",  5678, concentrate_pb:encode_msg(#miner_RxPacket_pb{payload= <<0:32/integer, 1:8/integer, Onion/binary>>,
                                                                                             bandwidth='BW125kHz',
                                                                                             spreading='SF8',
                                                                                             coderate='CR4_5',
                                                                                             freq=trunc(911.3e6),
                                                                                             radio='R0',
                                                                                             crc_check=true})),
    {ok, {{127,0,0,1}, 5678, Pkt1}} = gen_udp:recv(Sock, 0, 5000),
    #miner_TxPacket_pb{payload= <<0:32/integer, 1:8/integer, X/binary>>} = concentrate_pb:decode_msg(Pkt1, miner_TxPacket_pb),

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
        Parent ! {passed, Passed}
    end),

    {ok, _Server} = miner_onion_server:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey2)
    }),

    %% check we can't decrypt the original
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, concentrate_pb:encode_msg(#miner_RxPacket_pb{payload= <<0:32/integer, 1:8/integer, Onion/binary>>,
                                                                      bandwidth='BW125kHz',
                                                                      spreading='SF8',
                                                                      coderate='CR4_5',
                                                                      freq=trunc(911.3e6),
                                                                      radio='R0',
                                                                      crc_check=true})),

    ?assertEqual({error, timeout}, gen_udp:recv(Sock, 0, 1000)),

    ok = gen_udp:send(Sock, "127.0.0.1",  5678, concentrate_pb:encode_msg(#miner_RxPacket_pb{payload= <<0:32/integer, 1:8/integer, X/binary>>,
                                                                      bandwidth='BW125kHz',
                                                                      spreading='SF8',
                                                                      coderate='CR4_5',
                                                                      freq=trunc(911.3e6),
                                                                      radio='R0',
                                                                      crc_check=true})),
    {ok, {{127,0,0,1}, 5678, Pkt2}} = gen_udp:recv(Sock, 0, 5000),
    #miner_TxPacket_pb{payload= <<0:32/integer, 1:8/integer, Y/binary>>} = concentrate_pb:decode_msg(Pkt2, miner_TxPacket_pb),

    %% check we can't decrypt the next layer
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, concentrate_pb:encode_msg(#miner_RxPacket_pb{payload= <<0:32/integer, 1:8/integer, Y/binary>>,
                                                                      bandwidth='BW125kHz',
                                                                      spreading='SF8',
                                                                      coderate='CR4_5',
                                                                      freq=trunc(911.3e6),
                                                                      radio='R0',
                                                                      crc_check=true})),
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
    ok.
