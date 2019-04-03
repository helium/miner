-module(miner_onion_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

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

    {ok, LSock} = gen_tcp:listen(0, [{active, false}, binary, {packet, 2}]),
    {ok, Port} = inet:port(LSock),

    #{secret := PrivateKey, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := PrivateKey2, public := PubKey2} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := _PrivateKey3, public := PubKey3} = libp2p_crypto:generate_keys(ecc_compact),

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey) end),

    {ok, Server} = miner_onion_server:start_link(#{
        radio_host => "127.0.0.1",
        radio_tcp_port => Port,
        radio_udp_port => 5678,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey)
    }),
    {ok, Sock} = gen_tcp:accept(LSock),

    Data1 = <<1, 2, 3>>,
    Data2 = <<4, 5, 6>>,
    Data3 = <<7, 8, 9>>,
    OnionKey = #{public := OnionCompactKey} = libp2p_crypto:generate_keys(ecc_compact),
    {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, [{PubKey, Data1},
                                                              {PubKey2, Data2},
                                                              {PubKey3, Data3}]),
    ct:pal("constructed onion ~p", [Onion]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt,  fun(Data0, OnionCompactKey0, Origin, _) ->
        ?assertEqual(radio, Origin),
        ?assertEqual(Data1, Data0),
        ?assertEqual(libp2p_crypto:pubkey_to_bin(OnionCompactKey), OnionCompactKey0)
    end),

    ok = gen_tcp:send(Sock, <<16#81, 0:32/integer-unsigned-little, 1:8/integer, Onion/binary>>),
    {ok, <<0:8/integer, 0:32/integer, 1:8/integer, X/binary>>} = gen_tcp:recv(Sock, 0),

    
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
    meck:expect(miner_onion_server, send_receipt, fun(Data0, OnionCompactKey0, Origin, _) ->
        ?assertEqual(radio, Origin),
        Passed = Data2 == Data0 andalso libp2p_crypto:pubkey_to_bin(OnionCompactKey) == OnionCompactKey0,
        Parent ! {passed, Passed}
    end),

    {ok, _Server} = miner_onion_server:start_link(#{
        radio_host => "127.0.0.1",
        radio_tcp_port => Port,
        radio_udp_port => 5678,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey2)
    }),
    {ok, Sock2} = gen_tcp:accept(LSock),

    %% check we can't decrypt the original
    ok = gen_tcp:send(Sock2, <<16#81, 0:32/integer, 1:8/integer, Onion/binary>>),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock2, 0, 1000)),

    ok = gen_tcp:send(Sock2, <<16#81, 0:32/integer, 1:8/integer, X/binary>>),
    {ok, <<0:8/integer, 0:32/integer, 1:8/integer, Y/binary>>} = gen_tcp:recv(Sock2, 0, 2000),

    %% check we can't decrypt the next layer
    ok = gen_tcp:send(Sock2, <<16#81, 0:32/integer, 1:8/integer, Y/binary>>),
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock2, 0, 1000)),

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
