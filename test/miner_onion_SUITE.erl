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

    meck:new(blockchain_swarm, [passthrough]),
    meck:expect(blockchain_swarm, pubkey_bin, fun() -> libp2p_crypto:pubkey_to_bin(PubKey) end),

    {ok, _Server} = miner_onion_server:start_link(#{
        radio_host => "127.0.0.1",
        radio_port => Port,
        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivateKey)
    }),
    {ok, Sock} = gen_tcp:accept(LSock),

    Data = <<1, 2, 3>>,
    #{secret := PvtOnionKey, public := OnionCompactKey} = libp2p_crypto:generate_keys(ecc_compact),
    Onion = miner_onion_server:construct_onion({libp2p_crypto:mk_ecdh_fun(PvtOnionKey), OnionCompactKey}, [{Data, libp2p_crypto:pubkey_to_bin(PubKey)}]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt, fun(Data0, OnionCompactKey0) ->
        ?assertEqual(Data, Data0),
        ?assertEqual(crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)), OnionCompactKey0),
        ok
    end),

    ok = gen_tcp:send(Sock, <<16#81, Onion/binary>>),
    {ok, _} = gen_tcp:recv(Sock, 0),

    ?assert(meck:validate(miner_onion_server)),
    meck:unload(miner_onion_server),
    ?assert(meck:validate(blockchain_swarm)),
    meck:unload(blockchain_swarm),
    ok.
