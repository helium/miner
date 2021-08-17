%%% RELOC REMOVE - duplicates what is already done in miner_blockchain_SUITE
-module(miner_dkg_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include("miner_ct_macros.hrl").

-export([
         init_per_suite/1
         ,end_per_suite/1
         ,init_per_testcase/2
         ,end_per_testcase/2
         ,all/0
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
    miner_ct_utils:init_per_testcase(?MODULE, _TestCase, Config).

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

initial_dkg_test(Config) ->
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Keys = libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{}),
    InitialPaymentTransactions = [blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    InitialTransactions = InitialVars ++ InitialPaymentTransactions,
    NumConsensusMembers = ?config(num_consensus_members, Config),
    Curve = ?config(dkg_curve, Config),

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, InitialTransactions, Addresses,
                                            NumConsensusMembers, Curve),
    {comment, DKGCompletedNodes}.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

