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
          %% consensus_test,
          %% genesis_load_test,
          %% growth_test,
          restart_test,
          election_test,
          group_change_test,
          master_key_test,
          version_change_test
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
    BlockTime = case TestCase of
                    restart_test ->
                        3000;
                    _ ->
                        proplists:get_value(block_time, Config)
                end,
    Interval = proplists:get_value(election_interval, Config),
    BatchSize = proplists:get_value(batch_size, Config),
    Curve = proplists:get_value(dkg_curve, Config),

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),

    Extras =
        case TestCase of
            _ ->
                #{}
        end,

    Vars = #{garbage_value => totes_garb,
             ?block_time => BlockTime,
             ?election_interval => Interval,
             ?num_consensus_members => NumConsensusMembers,
             ?batch_size => BatchSize,
             ?dkg_curve => Curve},
    FinalVars = maps:merge(Vars, Extras),
    ct:pal("final vars ~p", [FinalVars]),

    InitialVars =
        case TestCase of
            version_change_test ->
                miner_ct_utils:make_vars(Keys, FinalVars, legacy);
            _ ->
                miner_ct_utils:make_vars(Keys, FinalVars)
        end,

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
                                       [Txns, Addresses, NumConsensusMembers, Curve], 120000)
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


restart_test(Config) ->
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
                                           %% do any to increase the chance of interesting outcomes
                                           true == lists:any(fun(Miner) ->
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch == 2
                                                             end, shuffle(Miners))
                                   end, 90, timer:seconds(1)),

    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, stop, [miner], 300),
          ct_rpc:call(Miner, application, stop, [blockchain], 300)
     end
     || Miner <- lists:sublist(Miners, 1, 2)],

    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, miner_consensus_mgr, cancel_dkg, [], 300)
     end
     || Miner <- lists:sublist(Miners, 3, 4)],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             case ct_rpc:call(Miner, application, which_applications, [], 300) of
                                 {badrpc, _} ->
                                     false;
                                 Apps ->
                                     not lists:keymember(miner, 1, Apps)
                             end
                     end, lists:sublist(Miners, 1, 2))
           end, 40, 500),


    Data = string:trim(os:cmd("pwd")),
    Dirs = filelib:wildcard(Data ++ "/data_*{1,2}*"),

    %% just kill the consensus groups, we should be able to restore them

    [begin
         ct:pal("rm dir ~s", [Dir]),
         os:cmd("rm -r " ++ Dir ++ "/blockchain_swarm/groups/consensus_*")
     end
     || Dir <- Dirs],

    %% [ct_slave:start(Miner, Args) || Miner <- lists:sublist(Miners, 1, 4)],
    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, start, [blockchain], 300),
          ct_rpc:call(Miner, application, start, [miner], 300)
     end
     || Miner <- lists:sublist(Miners, 1, 2)],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             case ct_rpc:call(Miner, blockchain_worker, blockchain, [], 300) of
                                 {badrpc, _} ->
                                     false;
                                 _Else ->
                                     ct:pal("else ~p", [_Else]),
                                     true
                             end
                     end, Miners)
           end, 40, 500),

    %% [begin
    %%      %%ct_slave:stop(Miner)
    %%       ct_rpc:call(Miner, miner, hbbft_skip, [], 300),
    %%       MinerPid = ct_rpc:call(Miner, erlang, whereis, [miner], 300),
    %%       MinerPid ! block_timeout
    %%  end
    %%  || Miner <- Miners],

    ok = miner_ct_utils:wait_until(fun() ->
                                           true == lists:all(fun(Miner) ->
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch >= 3
                                                             end, shuffle(Miners))
                                   end, 90, timer:seconds(1)),

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
                        {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
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
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch >= 3
                                                             end, shuffle(Miners))
                                   end, 90, timer:seconds(1)),
    %% now to test rescue blocks.  first: kill the chain

    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, stop, [miner], 300),
          ct_rpc:call(Miner, application, stop, [blockchain], 300)
     end
     || Miner <- lists:sublist(Miners, 1, 4)],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             case ct_rpc:call(Miner, application, which_applications, [], 300) of
                                 {badrpc, _} ->
                                     false;
                                 Apps ->
                                     not lists:keymember(miner, 1, Apps)
                             end
                     end, lists:sublist(Miners, 1, 4))
           end, 120, 500),


    Data = string:trim(os:cmd("pwd")),
    Dirs = filelib:wildcard(Data ++ "/data_*{1,2,3,4}*"),

    [begin
         ct:pal("rm dir ~s", [Dir]),
         os:cmd("rm -r " ++ Dir ++ "/blockchain_swarm/groups/*")
     end
     || Dir <- Dirs],

    %% [ct_slave:start(Miner, Args) || Miner <- lists:sublist(Miners, 1, 4)],
    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, start, [blockchain], 300),
          ct_rpc:call(Miner, application, start, [miner], 300)
     end
     || Miner <- lists:sublist(Miners, 1, 4)],

    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             case ct_rpc:call(Miner, blockchain_worker, blockchain, [], 300) of
                                 {badrpc, _} ->
                                     false;
                                 _Else ->
                                     ct:pal("else ~p", [_Else]),
                                     true
                             end
                     end, Miners)
           end, 120, 500),

    %% second: make sure we're not making blocks anymore
    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    {fail, false} =
        miner_ct_utils:wait_until(
          fun() ->
                  true == lists:all(fun(Miner) ->
                                            try
                                                C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                                {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
                                                ct:pal("miner ~p height ~p", [Miner, Ht]),
                                                %% height might go up
                                                %% one, but it
                                                %% shouldn't go up 5
                                                Ht > (Height + 5)
                                            catch _:_ ->
                                                    false
                                            end
                                    end, shuffle(Miners))
          end, 10, timer:seconds(1)),

    %% third: mint and submit the rescue txn, shrinking the group at
    %% the same time.

    Addresses = proplists:get_value(addresses, Config),
    NewGroup = lists:sublist(Addresses, 3, 4),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, HeadBlock} = ct_rpc:call(hd(Miners), blockchain, head_block, [HChain2]),
    NewHeight = blockchain_block:height(HeadBlock) + 1,
    Hash = blockchain_block:hash_block(HeadBlock),

    Vars = #{num_consensus_members => 4},

    {Priv, _Pub} = proplists:get_value(master_key, Config),

    Txn = blockchain_txn_vars_v1:new(Vars, 3),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    VarsTxn = blockchain_txn_vars_v1:proof(Txn, Proof),

    {ElectionEpoch, _EpochStart} = blockchain_block_v1:election_info(HeadBlock),

    GrpTxn = blockchain_txn_consensus_group_v1:new(NewGroup, <<>>, Height, 0),

    ct:pal("new height is ~p", [NewHeight]),

    RescueBlock = blockchain_block_v1:rescue(
                    #{prev_hash => Hash,
                      height => NewHeight,
                      transactions => [VarsTxn, GrpTxn],
                      hbbft_round => NewHeight,
                      time => erlang:system_time(seconds),
                      election_epoch => ElectionEpoch + 1,
                      epoch_start => NewHeight}),

    EncodedBlock = blockchain_block:serialize(
                     blockchain_block_v1:set_signatures(RescueBlock, [])),

    RescueSigFun = libp2p_crypto:mk_sig_fun(Priv),

    RescueSig = RescueSigFun(EncodedBlock),

    SignedBlock = blockchain_block_v1:set_signatures(RescueBlock, [], RescueSig),

    %% now that we have a signed block, cause one of the nodes to
    %% absorb it (and gossip it around)
    FirstNode = hd(Miners),
    Chain = ct_rpc:call(FirstNode, blockchain_worker, blockchain, []),
    ct:pal("FirstNode Chain: ~p", [Chain]),
    Swarm = ct_rpc:call(FirstNode, blockchain_swarm, swarm, []),
    ct:pal("FirstNode Swarm: ~p", [Swarm]),
    N = length(Miners),
    ct:pal("N: ~p", [N]),
     _ = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [Swarm, SignedBlock, Chain, N, self()]),

    ok =
        miner_ct_utils:wait_until(
          fun() ->
                  true == lists:all(fun(Miner) ->
                                            try
                                                C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                                {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
                                                ct:pal("miner ~p height ~p", [Miner, Ht]),
                                                %% height might go up
                                                %% one, but it
                                                %% shouldn't go up 5
                                                Ht > (NewHeight + 3)
                                            catch _:_ ->
                                                    false
                                            end
                                    end, shuffle(Miners))
          end, 60, timer:seconds(1)),

    %% check consensus miners
    NewConsensusMiners = lists:filtermap(fun(Miner) ->
                                              true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], 500)
                                      end, Miners),

    %% check non consensus miners
    NewNonConsensusMiners = lists:filtermap(fun(Miner) ->
                                                 false == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], 500)
                                         end, Miners),

    StopList = lists:sublist(NewConsensusMiners, 2) ++ lists:sublist(NewNonConsensusMiners, 2),
    %% stop some nodes and restart them to check group restore works

    ct:pal("stop list ~p", [StopList]),

    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, stop, [miner], 300),
          ct_rpc:call(Miner, application, stop, [blockchain], 300)
     end
     || Miner <- StopList],

    timer:sleep(5000),

    [begin
         %%ct_slave:stop(Miner)
          ct_rpc:call(Miner, application, start, [miner], 300),
          ct_rpc:call(Miner, application, start, [blockchain], 300)
     end
     || Miner <- StopList],

    %% fourth: confirm that blocks and elections are proceeding
    ok = miner_ct_utils:wait_until(
           fun() ->
                   true == lists:all(fun(Miner) ->
                                             try
                                                 {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                 ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                 Epoch > ElectionEpoch + 1
                                             catch _:_ ->
                                                     false
                                             end
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
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 1
                                                             end, shuffle(Miners))
                                   end, 60, timer:seconds(1)),
    %% submit the transaction

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger1 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain1]),
    ?assertEqual({ok, totes_garb}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger1])),

    Vars = #{num_consensus_members => 7},

    {Priv, _Pub} = proplists:get_value(master_key, Config),


    Txn = blockchain_txn_vars_v1:new(Vars, 2, #{version_predicate => 2,
                                                unsets => [garbage_value]}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),
    %% wait for it to take effect

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
         || Miner <- Miners],

    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    ok = miner_ct_utils:wait_until(
           fun() ->
                   true == lists:all(fun(Miner) ->
                                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, [], 500),
                                             {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C], 500),
                                             ct:pal("miner ~p height ~p target ~p", [Miner, Ht, Height+20]),
                                             Ht > (Height + 20)
                                     end, shuffle(Miners))
           end, 80, timer:seconds(1)),

    %% make sure we still haven't executed it
    C = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    L = ct_rpc:call(hd(Miners), blockchain, ledger, [C]),
    {ok, Members} = ct_rpc:call(hd(Miners), blockchain_ledger_v1, consensus_members, [L]),
    ?assertEqual(4, length(Members)),

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
                                           ct:pal("group size: ~p", [length(CGroup)]),
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
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 1
                                                             end, shuffle(Miners))
                                   end, 30, timer:seconds(1)),


    %% baseline: chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = proplists:get_value(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn1_0),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1])
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
    Txn2_0 = blockchain_txn_vars_v1:new(Vars2, 3, #{master_key => BinPub2}),
    Proof2 = blockchain_txn_vars_v1:create_proof(Priv, Txn2_0),
    KeyProof2 = blockchain_txn_vars_v1:create_proof(Priv2, Txn2_0),
    KeyProof2Corrupted = <<Proof2/binary, "asdasdasdas">>,
    Txn2_1 = blockchain_txn_vars_v1:proof(Txn2_0, Proof2),
    Txn2_2c = blockchain_txn_vars_v1:key_proof(Txn2_1, KeyProof2Corrupted),

    {ok, Start2} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_2c])
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
           end, 60, timer:seconds(1)),

    %% good master key

    Txn2_2 = blockchain_txn_vars_v1:key_proof(Txn2_1, KeyProof2),
    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_2])
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
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 4),
    Proof4 = blockchain_txn_vars_v1:create_proof(Priv, Txn4_0),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
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
           end, 80, timer:seconds(1)),

    %% double check that new master key works

    Vars5 = #{garbage_value => goats_always_win},
    Txn5_0 = blockchain_txn_vars_v1:new(Vars5, 4),
    Proof5 = blockchain_txn_vars_v1:create_proof(Priv2, Txn5_0),
    Txn5_1 = blockchain_txn_vars_v1:proof(Txn5_0, Proof5),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn5_1])
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



version_change_test(Config) ->
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
                                                                     {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 250),
                                                                     ct:pal("miner ~p Epoch ~p", [Miner, Epoch]),
                                                                     Epoch > 1
                                                             end, shuffle(Miners))
                                   end, 30, timer:seconds(1)),


    %% baseline: old-style chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = proplists:get_value(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Proof = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars),
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1])
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

    %% switch chain version

    Vars2 = #{?chain_vars_version => 2},
    Proof2 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars2),
    Txn2_0 = blockchain_txn_vars_v1:new(Vars2, 3),
    Txn2_1 = blockchain_txn_vars_v1:proof(Txn2_0, Proof2),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_1])
         || Miner <- Miners],

    %% make sure that it has taken effect
    ok = miner_ct_utils:wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             {ok, 2} ==
                                 ct_rpc:call(Miner, blockchain, config, [?chain_vars_version,
                                                                         Ledger])
                     end, shuffle(Miners))
           end, 60, timer:seconds(1)),

    %% try a new-style txn change

    Vars3 = #{garbage_value => goats_are_not_garb},
    Txn3_0 = blockchain_txn_vars_v1:new(Vars3, 4),
    Proof3 = blockchain_txn_vars_v1:create_proof(Priv, Txn3_0),
    Txn3_1 = blockchain_txn_vars_v1:proof(Txn3_0, Proof3),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn3_1])
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


    %% make sure old style is now closed off.

    Vars4 = #{garbage_value => goats_are_too_garb},
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 5),
    Proof4 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars4),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
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
    ok.
