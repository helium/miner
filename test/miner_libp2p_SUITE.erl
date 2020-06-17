-module(miner_libp2p_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
         p2p_addr_test/1,
         listen_addr_test/1
        ]).

%% common test callbacks

all() -> [
          p2p_addr_test
          ,listen_addr_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config) ->
    miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config).

end_per_testcase(TestCase, Config) ->
    miner_ct_utils:end_per_testcase(TestCase, Config).

%% test cases
listen_addr_test(Config) ->
    Miners = ?config(miners, Config),
    ListenAddrs = lists:foldl(fun(Miner, Acc) ->
                                      Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, []),
                                      LA = ct_rpc:call(Miner, libp2p_swarm, sessions, [Swarm]),
                                      [{Miner, LA} | Acc]
                              end, [], Miners),
    ?assertEqual(length(Miners), length(ListenAddrs)),
    {comment, ListenAddrs}.

p2p_addr_test(Config) ->
    Miners = ?config(miners, Config),
    P2PAddrs = lists:foldl(fun(Miner, Acc) ->
                                   Address = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
                                   P2PAddr = ct_rpc:call(Miner, libp2p_crypto, pubkey_bin_to_p2p, [Address]),
                                   [{Miner, P2PAddr} | Acc]
                           end, [], Miners),
    ?assertEqual(length(Miners), length(P2PAddrs)),
    {comment, P2PAddrs}.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
