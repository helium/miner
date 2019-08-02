-module(miner_blockchain_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

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
          group_change_test,
          master_key_test
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

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),

    InitialVars = miner_ct_utils:make_vars(Keys, #{garbage_value => totes_garb,
                                                   ?block_time => BlockTime,
                                                   ?election_interval => Interval,
                                                   ?num_consensus_members => NumConsensusMembers,
                                                   ?batch_size => BatchSize,
                                                   ?dkg_curve => Curve}),

    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/1000000}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitGen = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- lists:zip(Addresses, Locations)],
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
                                   end, 30, timer:seconds(1)),

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
                                                                     Epoch > 1
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

    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    ok = miner_ct_utils:wait_until(
           fun() ->
                   true == lists:all(fun(Miner) ->
                                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                             {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
                                             ct:pal("miner ~p height ~p", [Miner, Ht]),
                                             Ht > (Height + 20)
                                                             end, shuffle(Miners))
                                   end, 40, timer:seconds(1)),

    %% make sure we still haven't executed it
    CGroup1 = lists:filtermap(
                fun(Miner) ->
                        true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                end, Miners),
    ?assertEqual(4, length(CGroup1)),

    %% alter the "version" for all of them.
    lists:foreach(
      fun(Miner) ->
              ct_rpc:call(Miner, miner, inc_tv, [rand:uniform(4)]), %% make sure we're exercising the summing
              ct:pal("test version ~p ~p", [Miner, ct_rpc:call(Miner, miner, test_version, [], 1000)])
      end, Miners),

    %% wait for the change to take effect
    ok = miner_ct_utils:wait_until(fun() ->
                                           CGroup = lists:filtermap(
                                                      fun(Miner) ->
                                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                                                      end, Miners),
                                           7 == length(CGroup)
                                   end, 60, timer:seconds(1)),

    Blockchain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger2 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain2]),
    ?assertEqual({error, not_found}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger2])),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height2} = ct_rpc:call(hd(Miners), blockchain, height, [HChain2]),

    ct:pal("post change miner ~p height ~p", [hd(Miners), Height2]),
    %% TODO: probably need to parameterize this via the delay
    ?assert(Height2 > Height + 20 + 10),

    ok.

master_key_test(Config) ->
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

    ?assertEqual(7, length(ConsensusMiners)),

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
                                                                     Epoch > 1
                                                             end, shuffle(Miners))
                                   end, 30, timer:seconds(1)),


    %% baseline: chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = proplists:get_value(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Vars),
    ConsensusTxn = blockchain_txn_vars_v1:new(Vars, Proof, 2, #{}),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [ConsensusTxn])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             {ok, totes_goats_garb} == ct_rpc:call(Miner, blockchain, config, [garbage_value, Ledger])
                     end, shuffle(Miners))
           end, 40, timer:seconds(1)),

    %% bad master key

    #{secret := Priv2, public := Pub2} =
        libp2p_crypto:generate_keys(ecc_compact),

    BinPub2 = libp2p_crypto:pubkey_to_bin(Pub2),

    Vars2 = #{garbage_value => goats_are_not_garb},
    Proof2 = blockchain_txn_vars_v1:create_proof(Priv, Vars2),
    KeyProof2 = blockchain_txn_vars_v1:create_proof(Priv2, Vars2),
    KeyProof2Corrupted = <<KeyProof2/binary, "asdasdasdas">>,
    ConsensusTxn2 = blockchain_txn_vars_v1:new(Vars2, Proof2, 3, #{master_key => BinPub2,
                                                                   key_proof => KeyProof2Corrupted}),
    {ok, Start2} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [ConsensusTxn2])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
                             ct:pal("miner ~p height ~p", [Miner, Ht]),
                             Ht > (Start2 + 15) andalso
                                 {ok, totes_goats_garb} ==
                                 ct_rpc:call(Miner, blockchain, config, [garbage_value, Ledger])
                     end, shuffle(Miners))
           end, 40, timer:seconds(1)),

    %% good master key

    ConsensusTxn3 = blockchain_txn_vars_v1:new(Vars2, Proof2, 4, #{master_key => BinPub2,
                                                                   key_proof => KeyProof2}),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [ConsensusTxn3])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             Val = ct_rpc:call(Miner, blockchain, config, [garbage_value, Ledger]),
                             ct:pal("val ~p", [Val]),
                             {ok, goats_are_not_garb} == Val
                     end, shuffle(Miners))
           end, 40, timer:seconds(1)),


    %% make sure old master key is no longer working

    Vars4 = #{garbage_value => goats_are_too_garb},
    Proof4 = blockchain_txn_vars_v1:create_proof(Priv, Vars4),
    ConsensusTxn4 = blockchain_txn_vars_v1:new(Vars4, Proof4, 5, #{}),
    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [ConsensusTxn4])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
                             ct:pal("miner ~p height ~p", [Miner, Ht]),
                             Ht > (Start4 + 15) andalso
                                 {ok, goats_are_not_garb} ==
                                 ct_rpc:call(Miner, blockchain, config, [garbage_value, Ledger])
                     end, shuffle(Miners))
           end, 40, timer:seconds(1)),

    %% double check that new master key works

    Vars5 = #{garbage_value => goats_always_win},
    Proof5 = blockchain_txn_vars_v1:create_proof(Priv2, Vars5),
    ConsensusTxn5 = blockchain_txn_vars_v1:new(Vars5, Proof5, 6, #{}),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [ConsensusTxn5])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             Val = ct_rpc:call(Miner, blockchain, config, [garbage_value, Ledger]),
                             ct:pal("val ~p", [Val]),
                             {ok, goats_always_win} == Val
                     end, shuffle(Miners))
           end, 40, timer:seconds(1)),


    ok.
