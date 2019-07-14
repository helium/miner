-module(miner_dkg_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         initial_dkg_test/1
        ]).

%% common test callbacks

all() -> [
          initial_dkg_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    miner_ct_utils:init_per_testcase(_TestCase, Config).

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

initial_dkg_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),
    #{secret := Priv, public := Pub} = libp2p_crypto:generate_keys(ecc_compact),
    N = proplists:get_value(num_consensus_members, Config),
    Vars = #{num_consensus_members => N},
    BinPub = libp2p_crypto:pubkey_to_bin(Pub),
    KeyProof = blockchain_txn_vars_v1:create_proof(Priv, Vars),
    InitialVars = [ blockchain_txn_vars_v1:new(Vars, <<>>, #{master_key => BinPub, key_proof => KeyProof})],
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    Curve = proplists:get_value(dkg_curve, Config),

    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [InitialPaymentTransactions ++ InitialVars, Addresses, N, Curve])
                   end, Miners),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),
    {comment, DKGResults}.
