-module(miner_blockchain_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0,

         %% sigh
         election_check/3
        ]).

-export([
         consensus_test/1,
         genesis_load_test/1,
         growth_test/1,
         election_test/1
        ]).

%% common test callbacks

all() -> [
          consensus_test,
          genesis_load_test,
          growth_test,
          election_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(_TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Keys = proplists:get_value(keys, Config),
    Addresses = proplists:get_value(addresses, Config),

    #{secret := PrivKey, public := PubKey} =
        libp2p_crypto:generate_keys(ecc_compact),
    Owner = libp2p_crypto:pubkey_to_bin(PubKey),
    OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),


    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    InitAdd = [begin
                   Tx = blockchain_txn_add_gateway_v1:new(Owner, Addr),
                   SignedTx = blockchain_txn_add_gateway_v1:sign(Tx, OwnerSigFun),
                   blockchain_txn_add_gateway_v1:sign_request(SignedTx, GSigFun)
               end
               || {_, _, _, _, Addr, GSigFun} <- Keys],

    Txns = InitialPayment ++ InitAdd,
    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner, initial_dkg, [Txns, Addresses])
                   end, Miners),
    ?assertEqual([ok], lists:usort(DKGResults)),
    Config.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

consensus_test(Config) ->
    NumConsensusMiners = proplists:get_value(num_consensus_members, Config),
    Miners = proplists:get_value(miners, Config),
    NumNonConsensusMiners = length(Miners) - NumConsensusMiners,
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),
    ?assertEqual(NumConsensusMiners, length(ConsensusMiners)),
    ?assertEqual(NumNonConsensusMiners, length(Miners) - NumConsensusMiners),
    {comment, ConsensusMiners}.

genesis_load_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner, in_consensus, [])
                                         end, Miners),

    %% ensure that blockchain is undefined for non_consensus miners
    true = lists:all(fun(Res) ->
                             Res == undefined
                     end,
                     lists:foldl(fun(Miner, Acc) ->
                                         R = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                         [R | Acc]
                                 end, [], NonConsensusMiners)),

    %% get the genesis block from the first Consensus Miner
    ConsensusMiner = hd(lists:filtermap(fun(Miner) ->
                                                true == ct_rpc:call(Miner, miner, in_consensus, [])
                                        end, Miners)),

    Blockchain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),

    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Blockchain]),

    GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                     ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                             end, NonConsensusMiners),
    {comment, GenesisLoadResults}.

growth_test(Config) ->
    Miners = proplists:get_value(miners, Config),

    %% check consensus miners
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner, in_consensus, [])
                                         end, Miners),

    %% get the first consensus miner
    FirstConsensusMiner = hd(ConsensusMiners),

    Blockchain = ct_rpc:call(FirstConsensusMiner, blockchain_worker, blockchain, []),

    %% get the genesis block from first consensus miner
    {ok, GenesisBlock} = ct_rpc:call(FirstConsensusMiner, blockchain, genesis_block, [Blockchain]),

    %% check genesis load results for non consensus miners
    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    %% wait till the chain reaches height 2 for all miners
    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     C0 = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                                                     {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0]),
                                                                     ct:pal("miner ~p height ~p", [Miner, Height]),
                                                                     Height >= 5
                                                             end, Miners)
                                   end, 120, timer:seconds(1)),

    Heights = lists:foldl(fun(Miner, Acc) ->
                                  C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                  {ok, H} = ct_rpc:call(Miner, blockchain, height, [C]),
                                  [{Miner, H} | Acc]
                          end, [], Miners),

    {comment, Heights}.


election_test(Config) ->
    %% get all the miners
    Miners = proplists:get_value(miners, Config),

    %% check consensus miners
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner, in_consensus, [])
                                         end, Miners),

    %% get the first consensus miner
    FirstConsensusMiner = hd(ConsensusMiners),

    Blockchain = ct_rpc:call(FirstConsensusMiner, blockchain_worker, blockchain, []),

    %% get the genesis block from first consensus miner
    {ok, GenesisBlock} = ct_rpc:call(FirstConsensusMiner, blockchain, genesis_block, [Blockchain]),

    %% check genesis load results for non consensus miners
    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    Me = self(),
    spawn(?MODULE, election_check, [Miners, Miners, Me]),

    fun Loop(0) ->
            error(timeout);
        Loop(N) ->
            receive
                seen_all ->
                    ok;
                {not_seen, []} ->
                    ok;
                {not_seen, Not} ->
                    Miner = lists:nth(rand:uniform(length(Miners)), Miners),
                    try
                        C0 = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                        {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0]),
                            ct:pal("not seen: ~p height ~p", [Not, Height])
                    catch _:_ ->
                            ct:pal("not seen: ~p ", [Not]),
                            ok
                    end,
                    Loop(N - 1)
            after timer:seconds(30) ->
                    error(timeout)
            end
    end(120),
    %% we've seen all of the nodes, yay.  now make sure that more than
    %% one election can happen.
    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     C0 = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                                                     {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0]),
                                                                     ct:pal("miner ~p height ~p", [Miner, Height]),
                                                                     Height > 16
                                                             end, shuffle(Miners))
                                  end, 120, timer:seconds(1)),
    ok.

election_check([], _Miners, Owner) ->
    Owner ! seen_all;
election_check(NotSeen0, Miners, Owner) ->
    timer:sleep(500),
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner, in_consensus, [])
                                      end, Miners),
    NotSeen = NotSeen0 -- ConsensusMiners,
    Owner ! {not_seen, NotSeen},
    election_check(NotSeen, Miners, Owner).


shuffle(List) ->
    R = [{rand:uniform(1000000), I} || I <- List],
    O = lists:sort(R),
    {_, S} = lists:unzip(O),
    S.
