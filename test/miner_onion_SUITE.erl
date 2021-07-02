-module(miner_onion_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("miner_ct_macros.hrl").
-include("lora.hrl").

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
basic(Config) ->
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),

    BaseDir = ?config(base_dir, Config),
    Ledger = blockchain_ledger_v1:new(BaseDir),
    BlockHash = crypto:strong_rand_bytes(32),

    {ok, Sock} = gen_udp:open(0, [{active, false}, binary, {reuseaddr, true}]),
    {ok, Port} = inet:port(Sock),

    #{secret := PrivateKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := PrivateKey2, public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := _PrivateKey3, public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey) end),

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

    {ok, Server} = miner_onion_server:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey)
    }),

    {ok, RadioServer} = miner_lora:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        sig_fun => libp2p_crypto:mk_sig_fun(PrivateKey),
        region_override => 'US915'
    }),


    Data1 = <<1, 2>>,
    Data2 = <<3, 4>>,
    Data3 = <<5, 6>>,
    OnionKey = #{public := OnionCompactKey} = libp2p_crypto:generate_keys(ecc_compact),

    {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, [{PubKey, Data1},
                                                              {PubKey2, Data2},
                                                              {PubKey3, Data3}], BlockHash, Ledger),
    ct:pal("constructed onion ~p", [Onion]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt,  fun(Data0, OnionCompactKey0, Origin, _Time, _RSSI, _SNR, _Frequency, _Channel, _DataRate, _Stream, _Power, _State) ->
        ?assertEqual(radio, Origin),
        ?assertEqual(Data1, Data0),
        ?assertEqual(libp2p_crypto:pubkey_to_bin(OnionCompactKey), OnionCompactKey0)
    end),

    Token = <<0, 0>>,
    %% set up the gateway
    gen_udp:send(Sock, {127, 0, 0, 1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, 16#deadbeef:64/integer>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),

    Packet = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(monolithic, 0, 1, 0, Onion, #{})),
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer,
                                                  (jsx:encode(#{<<"rxpk">> =>
                                                             [#{<<"rssi">> => -42, <<"lsnr">> => 1.0,
                                                                <<"tmst">> => erlang:system_time(seconds), <<"freq">> => 903.9,
                                                                <<"datr">> => <<"SF10BW125">>, <<"data">> => base64:encode(Packet)}]}))/binary>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, _Token1:2/binary, ?PULL_RESP:8/integer-unsigned, PacketJSON1/binary>>}} = gen_udp:recv(Sock, 0, 5000),

    #{<<"txpk">> := #{<<"data">> := Packet1}} = jsx:decode(PacketJSON1, [return_maps]),

    {ok, LongFiPkt1} = longfi:deserialize(base64:decode(Packet1)),

    X = longfi:payload(LongFiPkt1),
    timer:sleep(2000),
    %% check that the packet size is the same
    ?assertEqual(erlang:byte_size(Onion), erlang:byte_size(X)),
    gen_server:stop(Server),
    gen_server:stop(RadioServer),
    ct:pal("~p~n", [X]),

    ?assert(meck:validate(miner_onion_server)),
    meck:unload(miner_onion_server),
    ?assert(meck:validate(blockchain_swarm)),
    meck:unload(blockchain_swarm),

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey2) end),

    Parent = self(),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt,  fun(Data0, OnionCompactKey0, Origin, _Time, _RSSI, _SNR, _Frequency, _Channel, _DataRate, _Stream, _Power, _State) ->
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

    {ok, RadioServer1} = miner_lora:start_link(#{
        radio_udp_bind_ip => {127,0,0,1},
        radio_udp_bind_port => 5678,
        radio_udp_send_ip => {127,0,0,1},
        radio_udp_send_port => Port,
        sig_fun => libp2p_crypto:mk_sig_fun(PrivateKey2),
        region_override => 'US915'
    }),

    %% set up the gateway
    gen_udp:send(Sock, {127, 0, 0, 1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, 16#deadbeef:64/integer>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),

    %% check we can't decrypt the original
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer,
                                                  (jsx:encode(#{<<"rxpk">> =>
                                                             [#{<<"rssi">> => -42, <<"lsnr">> => 1.0,
                                                                <<"tmst">> => erlang:system_time(seconds), <<"freq">> => 903.9,
                                                                <<"datr">> => <<"SF10BW125">>, <<"data">> => base64:encode(Packet)}]}))/binary>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),
    ?assertEqual({error, timeout}, gen_udp:recv(Sock, 0, 1000)),


    ok = gen_udp:send(Sock, "127.0.0.1",  5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer,
                                                  (jsx:encode(#{<<"rxpk">> =>
                                                                [#{<<"rssi">> => -42, <<"lsnr">> => 1.0,
                                                                   <<"tmst">> => erlang:system_time(seconds), <<"freq">> => 903.9,
                                                                   <<"datr">> => <<"SF10BW125">>, <<"data">> => Packet1}]}))/binary>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token2:2/binary, ?PULL_RESP:8/integer-unsigned, PacketJSON2/binary>>}} = gen_udp:recv(Sock, 0, 5000),
    gen_udp:send(Sock, {127, 0, 0, 1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token2:2/binary, ?PULL_ACK:8/integer-unsigned, 16#deadbeef:64/integer>>),

    #{<<"txpk">> := #{<<"data">> := Packet2}} = jsx:decode(PacketJSON2, [return_maps]),
    {ok, LongFiPkt2} = longfi:deserialize(base64:decode(Packet2)),

    Y = longfi:payload(LongFiPkt2),

    %% check we can't decrypt the next layer
    ok = gen_udp:send(Sock, "127.0.0.1",  5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer,
                                                  (jsx:encode(#{<<"rxpk">> =>
                                                                [#{<<"rssi">> => -42, <<"lsnr">> => 1.0,
                                                                   <<"tmst">> => erlang:system_time(seconds), <<"freq">> => 903.9,
                                                                   <<"datr">> => <<"SF10BW125">>, <<"data">> => Packet2}]}))/binary>>),
    {ok, {{127,0,0,1}, 5678, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>}} = gen_udp:recv(Sock, 0, 5000),
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
    meck:unload(blockchain_swarm),
    ?assert(meck:validate(blockchain_worker)),
    meck:unload(blockchain_worker),
    ?assert(meck:validate(blockchain)),
    meck:unload(blockchain),
    ?assert(meck:validate(blockchain_ledger_v1)),
    meck:unload(blockchain_ledger_v1),
    gen_server:stop(Server1),
    gen_server:stop(RadioServer1),
    ok.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
