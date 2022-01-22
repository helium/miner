-module(miner_gateway_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

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
    ok = application:set_env(blockchain, key, {gateway_ecc, [{key_slot, 0}]}),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_Case, Config) ->
    application:ensure_all_started(miner),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

gateway_signing_test(_Config) ->
    ?assert(is_pid(whereis(miner_gateway_port))),
    ?assert(is_pid(whereis(miner_gateway_ecc_worker))),

    {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
    ?assertMatch({ecc_compact, {{'ECPoint',_},{namedCurve,_}}}, PubKey),

    Binary = <<"go go gadget gateway">>,
    {ok, Signature} = miner_gateway_ecc_worker:sign(Binary),
    ?assert(libp2p_crypto:verify(Binary, Signature, PubKey)),

    {ok, PrivKeyBin} = file:read_file(code:priv_dir(miner) ++ "/gateway_rs/gateway_key.bin"),
    #{secret := PrivKey} = libp2p_crypto:keys_from_bin(PrivKeyBin),
    VerifyFun = libp2p_crypto:mk_ecdh_fun(PrivKey),

    {ok, GatewayEcdhPreseed} = miner_gateway_ecc_worker:ecdh(PubKey),
    VerifyPreseed = VerifyFun(PubKey),

    ?assertEqual(GatewayEcdhPreseed, VerifyPreseed),
    ok.
