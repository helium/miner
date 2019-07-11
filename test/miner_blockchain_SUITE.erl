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

-compile([export_all]).

%% common test callbacks

all() -> [
          consensus_test,
          genesis_load_test,
          growth_test,
          election_test,
          group_change_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(TestCase, Config0),
    Miners = proplists:get_value(miners, Config),
    Addresses = proplists:get_value(addresses, Config),

    NumConsensusMembers = proplists:get_value(num_consensus_members, Config),
    BlockTime = proplists:get_value(block_time, Config),
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),
    %% VarCommitInterval = proplists:get_value(var_commit_interval, Config),

    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars = #{block_time => BlockTime,
             election_interval => Interval,
             election_restart_interval => 10,
             num_consensus_members => NumConsensusMembers,
             batch_size => BatchSize,
             vars_commit_delay => 2,
             block_version => v1,
             dkg_curve => Curve,
             garbage_value => totes_garb,
             predicate_callback_mod => miner,
             predicate_callback_fun => test_version,
             predicate_threshold => 0.85,
             monthly_reward => 50000 * 1000000,
             securities_percent => 0.35,
             dc_percent => 0,
             poc_challengees_percent => 0.19 + 0.16,
             poc_challengers_percent => 0.09 + 0.06,
             poc_witnesses_percent => 0.02 + 0.03,
             consensus_percent => 0.10,
             election_selection_pct => 60,
             election_replacement_factor => 4,
             election_replacement_slope => 20,
             min_score => 0.2,
             h3_ring_size => 2,
             h3_path_res => 8,
             alpha_decay => 0.007,
             beta_decay => 0.0005,
             max_staleness => 100000
            },

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),
    KeyProof = blockchain_txn_vars_v1:create_proof(Priv, Vars),

    ct:pal("master key ~p~n priv ~p~n vars ~p~n keyproof ~p~n artifact ~p",
           [BinPub, Priv, Vars, KeyProof,
            term_to_binary(Vars, [{compressed, 9}])]),

    InitialVars = [ blockchain_txn_vars_v1:new(Vars, <<>>, 1, #{master_key => BinPub,
                                                                key_proof => KeyProof}) ],

    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    InitGen = [begin
                   blockchain_txn_gen_gateway_v1:new(Addr, Addr, 16#8c283475d4e89ff, 0)
               end
               || Addr <- Addresses],
    Txns = InitialVars ++ InitialPayment ++ InitGen,
    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [Txns, Addresses, NumConsensusMembers, Curve])
                   end, Miners),
    ?assertEqual([ok], lists:usort(DKGResults)),
    [{master_key, {Priv, Pub}} | Config].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

consensus_test(Config) ->
    NumConsensusMiners = proplists:get_value(num_consensus_members, Config),
    Miners = proplists:get_value(miners, Config),
    NumNonConsensusMiners = length(Miners) - NumConsensusMiners,
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                      end, Miners),
    ?assertEqual(NumConsensusMiners, length(ConsensusMiners)),
    ?assertEqual(NumNonConsensusMiners, length(Miners) - NumConsensusMiners),
    {comment, ConsensusMiners}.

genesis_load_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
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
                                                true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
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
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
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
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
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
                        Epoch = ct_rpc:call(Miner, miner, election_epoch, []),
                        {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0]),
                            ct:pal("not seen: ~p height ~p ~p", [Not, Epoch, Height])
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
                                                                     Epoch = ct_rpc:call(Miner, miner, election_epoch, []),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 3
                                                             end, shuffle(Miners))
                                           %%TODO fixme back to 120s
                                           %%for slow machines
                                  end, 90, timer:seconds(1)),
    ok.

election_check([], _Miners, Owner) ->
    Owner ! seen_all;
election_check(NotSeen0, Miners, Owner) ->
    timer:sleep(500),
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                      end, Miners),
    NotSeen = NotSeen0 -- ConsensusMiners,
    Owner ! {not_seen, NotSeen},
    election_check(NotSeen, Miners, Owner).


shuffle(List) ->
    R = [{rand:uniform(1000000), I} || I <- List],
    O = lists:sort(R),
    {_, S} = lists:unzip(O),
    S.


group_change_test(Config) ->
    %% get all the miners
    Miners = proplists:get_value(miners, Config),

    %% check consensus miners
    ConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                      end, Miners),

    %% check non consensus miners
    NonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                         end, Miners),

    ?assertNotEqual([], ConsensusMiners),
    %% get the first consensus miner
    FirstConsensusMiner = hd(ConsensusMiners),

    ?assertEqual(4, length(ConsensusMiners)),

    Blockchain = ct_rpc:call(FirstConsensusMiner, blockchain_worker, blockchain, []),

    %% get the genesis block from first consensus miner
    {ok, GenesisBlock} = ct_rpc:call(FirstConsensusMiner, blockchain, genesis_block, [Blockchain]),

    %% check genesis load results for non consensus miners
    _GenesisLoadResults = miner_ct_utils:pmap(fun(M) ->
                                                      ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                                              end, NonConsensusMiners),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     Epoch = ct_rpc:call(Miner, miner, election_epoch, []),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 2
                                                             end, shuffle(Miners))
                                   end, 30, timer:seconds(1)),
    %% submit the transaction

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger1 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain1]),
    ?assertEqual({ok, totes_garb}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger1])),

    Vars = #{num_consensus_members => 7},

    {Priv, _Pub} = proplists:get_value(master_key, Config),

    Proof = blockchain_txn_vars_v1:create_proof(Priv, Vars),

    Txn = blockchain_txn_vars_v1:new(Vars, Proof, 2, #{version_predicate => 2,
                                                       unsets => [garbage_value]}),
    %% wait for it to take effect

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     Epoch = ct_rpc:call(Miner, miner, election_epoch, []),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 5
                                                             end, shuffle(Miners))
                                   end, 60, timer:seconds(1)),

    %% make sure we still haven't executed it
    CGroup1 = lists:filtermap(
                fun(Miner) ->
                        true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                end, Miners),
    ?assertEqual(4, length(CGroup1)),

    %% alter the "version" for all of them.
    lists:foreach(
      fun(Miner) ->
              ct_rpc:call(Miner, miner, inc_tv, [rand:uniform(4)]) %% make sure we're exercising the summing
      end, Miners),

    %% wait for the change to take effect
    ok = miner_ct_utils:wait_until(fun() ->
                                           CGroup = lists:filtermap(
                                                      fun(Miner) ->
                                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                                      end, Miners),
                                           7 == length(CGroup)
                                   end, 120, timer:seconds(1)),

    Blockchain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger2 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain2]),
    ?assertEqual({error, not_found}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger2])),

    %% check that the epoch delay is at least 2
    Epoch = ct_rpc:call(hd(Miners), miner, election_epoch, []),
    ct:pal("post change miner ~p Epoch ~p", [hd(Miners), Epoch]),
    %% probably need to parameterize this via the delay
    ?assert(9 =< Epoch),

    ok.
