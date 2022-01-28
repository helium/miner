-module(miner_gateway_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-export([
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    all/0
]).

-export([gateway_signing_test/1]).

all() ->
    [gateway_signing_test].

init_per_suite(Config) ->
    ok = application:set_env(miner, gateway_and_mux_enable, true),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    application:ensure_all_started(miner),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(miner),
    ok.

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
