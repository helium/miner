-module(miner_blockchain_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([
    autoskip_chain_vars_test/1,
    autoskip_on_timeout_test/1,
    restart_test/1,
    dkg_restart_test/1,
    validator_transition_test/1,
    election_test/1,
    election_multi_test/1,
    group_change_test/1,
    election_v3_test/1,

    snapshot_test/1,
    high_snapshot_test/1
]).

%% TODO Relocate all helper functions bellow tests.

all() -> [
    % RELOC NOTE def KEEP testing of DKG
    % RELOC NOTE def KEEP testing of election
    % RELOC NOTE def MOVE testing of variable changes
    % RELOC NOTE may MOVE if raw transactions are being submitted

    autoskip_chain_vars_test,
    %% RELOC KEEP - tests miner-unique feature

    autoskip_on_timeout_test,
    %% RELOC KEEP - tests miner-unique feature

    restart_test,
    %% RELOC KEEP - tests whole miner

    dkg_restart_test,
    %% RELOC KEEP - tests DKG

    validator_transition_test,
    %% RELOC TBD:
    %%   FOR:
    %%     - submits txns
    %%     - submits vars
    %%   AGAINST:
    %%     - seems to intend to test miner-specific functionality - validators

    election_test,
    %% RELOC KEEP - tests election

    election_multi_test,
    %% RELOC KEEP - tests election

    group_change_test,
    %% RELOC TBD:
    %%   FOR:
    %%     - seems to be mostly calling a single miner
    %%     - submits txns
    %%   AGAINST:
    %%     - seems to expect different outcomes in multiple miners

    election_v3_test,
    %% RELOC KEEP - tests election

    %% snapshot_test is an OK smoke test but doesn't hit every time, the
    %% high_snapshot_test test is more reliable:
    %%snapshot_test,
    high_snapshot_test
    %% RELOC KEEP - why?
].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    %% TODO Describe what global state we intend to setup, besides vals added to config.
    %% TODO Redefine as a parameterized helper, because some cased need different params.

    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = case TestCase of
                    restart_test ->
                        3000;
                    _ ->
                        ?config(block_time, Config)
                end,
    Interval = ?config(election_interval, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),

    Extras =
        %% TODO Parametarize init_per_testcase instead leaking per-case internals.
        case TestCase of
            dkg_restart_test ->
                #{?election_interval => 10,
                  ?election_restart_interval => 99};
            validator_test ->
                #{?election_interval => 5,
                  ?monthly_reward => ?bones(1000),
                  ?election_restart_interval => 5};
            validator_unstake_test ->
                #{?election_interval => 5,
                  ?election_restart_interval => 5};
            validator_transition_test ->
                #{?election_version => 4,
                  ?election_interval => 5,
                  ?election_restart_interval => 5};
            autoskip_chain_vars_test ->
                #{?election_interval => 100};
            T when T == snapshot_test;
                   T == high_snapshot_test;
                   T == group_change_test ->
                #{?snapshot_version => 1,
                  ?snapshot_interval => 5,
                  ?election_bba_penalty => 0.01,
                  ?election_seen_penalty => 0.05,
                  ?election_version => 5};
            election_v3_test ->
                #{
                  ?election_version => 2
                 };
            _ ->
                #{}
        end,

    Vars = #{garbage_value => totes_garb,
             ?block_time => max(3000, BlockTime),
             ?election_interval => Interval,
             ?num_consensus_members => NumConsensusMembers,
             ?batch_size => BatchSize,
             ?dkg_curve => Curve},
    FinalVars = maps:merge(Vars, Extras),
    ct:pal("final vars ~p", [FinalVars]),

    InitialVars = miner_ct_utils:make_vars(Keys, FinalVars),
    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    %% create a new account to own validators for staking
    #{public := AuxPub} = AuxKeys = libp2p_crypto:generate_keys(ecc_compact),
    AuxAddr = libp2p_crypto:pubkey_to_bin(AuxPub),
     Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/50}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitGen =
        case blockchain_txn_vars_v1:decoded_vars(hd(InitialVars)) of
            #{?election_version := V} when V >= 5 ->
                [blockchain_txn_gen_validator_v1:new(Addr, Addr, ?bones(10000))
                 || Addr <- Addresses] ++ [blockchain_txn_coinbase_v1:new(AuxAddr, ?bones(15000))];
            _ ->
                [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
                 || {Addr, Loc} <- lists:zip(Addresses, Locations)] ++
                    %% bigger stake for transfer test
                    [blockchain_txn_coinbase_v1:new(AuxAddr, ?bones(150000))]
        end,
    Txns = InitialVars ++ InitialPayment ++ InitGen,

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 3, all, 15),

    [   {master_key, {Priv, Pub}},
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners},
        {aux_acct, {AuxAddr, AuxKeys}}
        | Config]
    catch
        What:Why:Stack ->
            end_per_testcase(TestCase, Config),
            ct:pal("Stack ~p", [Stack]),
            erlang:What(Why)
    end.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).

autoskip_chain_vars_test(Config) ->
    %% The idea here is to reproduce the following chain stall scenario:
    %% 1. 1/2 of consensus members recognize a new chain var;
    %% 2. 1/2 of consensus members do not;
    %% 3.
    %%      If autoskip doesn't work:
    %%          chain halts - no more blocks are created on any of the nodes
    %%      otherwise
    %%          chain advances, so autoskip must've worked

    MinersAll = ?config(miners, Config),
    MinersInConsensus = miner_ct_utils:in_consensus_miners(MinersAll),
    N = length(MinersInConsensus),
    ?assert(N > 1, "We have at least 2 miner nodes."),
    M = N div 2,
    ?assertEqual(N, 2 * M, "Even split of consensus nodes."),
    MinersWithBogusVar = lists:sublist(MinersInConsensus, M),

    BogusKey = bogus_key,
    BogusVal = bogus_val,

    ct:pal("N: ~p", [N]),
    ct:pal("M: ~p", [M]),
    ct:pal("MinersAll: ~p", [MinersAll]),
    ct:pal("MinersInConsensus: ~p", [MinersInConsensus]),
    ct:pal("MinersWithBogusVar: ~p", [MinersWithBogusVar]),

    %% The mocked 1/2 of consensus group will allow bogus vars:
    [
        ok =
            ct_rpc:call(
                Node,
                meck,
                expect,
                [blockchain_txn_vars_v1, is_valid, fun(_, _) -> ok end],
                300
            )
    ||
        Node <- MinersWithBogusVar
    ],

    %% Submit bogus var transaction:
    (fun() ->
        {SecretKey, _} = ?config(master_key, Config),
        Txn0 = blockchain_txn_vars_v1:new(#{BogusKey => BogusVal}, 2),
        Proof = blockchain_txn_vars_v1:create_proof(SecretKey, Txn0),
        Txn = blockchain_txn_vars_v1:proof(Txn0, Proof),
        miner_ct_utils:submit_txn(Txn, MinersInConsensus)
    end)(),

    AllHeights =
        fun() ->
            lists:usort([H || {_, H} <- miner_ct_utils:heights(MinersAll)])
        end,

    ?assert(
        miner_ct_utils:wait_until(
            fun() ->
                case AllHeights() of
                    [_] -> true;
                    [_|_] -> false
                end
            end,
            50,
            1000
        ),
        "Heights equalized."
    ),
    [Height1] = AllHeights(),
    ?assertMatch(
        ok,
        miner_ct_utils:wait_for_gte(height, MinersAll, Height1 + 10),
        "Chain has advanced, so autoskip must've worked."
    ),

    %% Extra sanity check - no one should've accepted the bogus var:
    ?assertMatch(
        [{error, not_found}],
        lists:usort(miner_ct_utils:chain_var_lookup_all(BogusKey, MinersAll)),
        "No node accepted the bogus chain var."
    ),

    {comment, miner_ct_utils:heights(MinersAll)}.

autoskip_on_timeout_test(Config) ->
    %% The idea is to reproduce the following chain stall scenario:
    %% 1. 1/2 of consensus members produce timed blocks;
    %% 2. 1/2 of consensus members do not;
    %% 3.
    %%      If time-based autoskip doesn't work:
    %%          chain halts - no more blocks are created on any of the nodes
    %%      otherwise
    %%          chain advances, so time-based autoskip must've worked

    MinersAll = ?config(miners, Config),
    MinersCG = miner_ct_utils:in_consensus_miners(MinersAll),
    N = length(MinersCG),
    ?assert(N > 1, "We have at least 2 miner nodes."),
    M = N div 2,
    ?assertEqual(N, 2 * M, "Even split of consensus nodes."),
    MinersCGBroken = lists:sublist(MinersCG, M),

    ct:pal("N: ~p", [N]),
    ct:pal("MinersAll: ~p", [MinersAll]),
    ct:pal("MinersCG: ~p", [MinersCG]),
    ct:pal("MinersCGBroken: ~p", [MinersCGBroken]),

    %% Default is 120 sesonds, but for testing we want to trigger skip faster:
    _ = [
        ok = ct_rpc:call(Node, application, set_env, [miner, late_block_timeout_seconds, 10], 300)
    ||
        Node <- MinersAll
    ],

    _ = [
        ok = ct_rpc:call(Node, miner, hbbft_skip, [], 300)
    ||
        Node <- MinersCGBroken
    ],
    _ = [
        ok = ct_rpc:call(Node, miner, hbbft_skip, [], 300)
    ||
        Node <- MinersCGBroken
    ],

    %% TODO The following needs better explanation and/or better methods.
    %% send some more skips at broken miner 1 so we're not all on the same round
    Node1 = hd(MinersCGBroken),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),
    ok = ct_rpc:call(Node1, miner, hbbft_skip, [], 300),

    ok = miner_ct_utils:assert_chain_halted(MinersAll),
    ok = miner_ct_utils:assert_chain_advanced(MinersAll, 2500, 5),

    {comment, miner_ct_utils:heights(MinersAll)}.

restart_test(Config) ->
    %% NOTES:
    %% restart_test is hitting coinsensus restore pathway
    %% consesus group is lost but dkg is retained
    %% 
    %% finish the dkg,
    %% crash,
    %% restart
    %%
    %% trying to check restore after crash
    %%
    %% the main is to test that group information is not lost after a crash
    %%
    BaseDir = ?config(base_dir, Config),
    Miners = ?config(miners, Config),

    %% wait till the chain reaches height 2 for all miners
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 60),

    Env = miner_ct_utils:stop_miners(lists:sublist(Miners, 1, 2)),

    [begin
          ct_rpc:call(Miner, miner_consensus_mgr, cancel_dkg, [], 300)
     end
     || Miner <- lists:sublist(Miners, 3, 4)],

    %% just kill the consensus groups, we should be able to restore them
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{1,2}*", "/blockchain_swarm/groups/consensus_*"),

    ok = miner_ct_utils:start_miners(Env),

    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 90),

    {comment, miner_ct_utils:heights(Miners)}.


dkg_restart_test(Config) ->
    %% TODO Describe main idea and method.
    Miners = ?config(miners, Config),
    Interval = ?config(election_interval, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    %% stop the out of consensus miners and the last two consensus
    %% members.  this should keep the dkg from completing
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, any, 90), % wait up to 90s for epoch to or exceed 2

    Members = miner_ct_utils:consensus_members(2, Miners),

    %% there are issues with this.  if it's more of a problem than the
    %% last time, we can either have the old list and reject it if we
    %% get it again, or we get all of them and select the majority one?
    {CMiners, NCMiners} = miner_ct_utils:partition_miners(Members, AddrList),
    FirstCMiner = hd(CMiners),
    Height = miner_ct_utils:height(FirstCMiner),
    Stoppers = lists:sublist(CMiners, 5, 2),
    %% make sure that everyone has accepted the epoch block
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 2),

    Stop1 = miner_ct_utils:stop_miners(NCMiners ++ Stoppers, 60),
    ct:pal("stopping nc ~p stoppers ~p", [NCMiners, Stoppers]),

    %% wait until we're sure that the election is running
    ok = miner_ct_utils:wait_for_gte(height, lists:sublist(CMiners, 1, 4), Height + (Interval * 2), all, 180),

    %% stop half of the remaining miners
    Restarters = lists:sublist(CMiners, 1, 2),
    ct:pal("stopping restarters ~p", [Restarters]),
    Stop2 = miner_ct_utils:stop_miners(Restarters, 60),

    %% restore that half
    ct:pal("starting restarters ~p", [Restarters]),
    miner_ct_utils:start_miners(Stop2, 60),

    %% restore the last two
    ct:pal("starting blockers"),
    miner_ct_utils:start_miners(Stop1, 60),

    %% make sure that we elect again
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, any, 90),

    %% make sure that we did the restore
    EndHeight = miner_ct_utils:height(FirstCMiner),
    ?assert(EndHeight < (Height + Interval + 99)).

validator_transition_test(Config) ->
    %% TODO Describe main idea and method.

    %% get all the miners
    Miners = ?config(miners, Config),
    Options = ?config(node_options, Config),
    {Owner, #{secret := AuxPriv}} = ?config(aux_acct, Config),
    AuxSigFun = libp2p_crypto:mk_sig_fun(AuxPriv),
    %% setup makes sure that the cluster is running, so the first thing is to create and connect two
    %% new nodes.

    Blockchain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(hd(Miners), blockchain, genesis_block, [Blockchain]),

    ListenAddrs = miner_ct_utils:get_addrs(Miners),
    ValidatorAddrList =
        [begin
             Num = integer_to_list(N),
             {NewVal, Keys} = miner_ct_utils:start_miner(list_to_atom(Num ++ miner_ct_utils:randname(5)), Options),
             {_, _, _, _Pub, Addr, _SigFun} = Keys,
             ct_rpc:call(NewVal, blockchain_worker, integrate_genesis_block, [GenesisBlock]),
             Swarm = ct_rpc:call(NewVal, blockchain_swarm, swarm, [], 2000),
             lists:foreach(
               fun(A) ->
                       ct_rpc:call(NewVal, libp2p_swarm, connect, [Swarm, A], 2000)
               end, ListenAddrs),
             UTxn1 = blockchain_txn_stake_validator_v1:new(Addr, Owner, ?bones(10000), 100000),
             Txn1 = blockchain_txn_stake_validator_v1:sign(UTxn1, AuxSigFun),

             _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn1]) || M <- Miners],
             {NewVal, Addr}
         end || N <- lists:seq(9, 12)],

    {Validators, _Addrs} = lists:unzip(ValidatorAddrList),

    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{?election_version => 5},

    UEVTxn = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, UEVTxn),
    EVTxn = blockchain_txn_vars_v1:proof(UEVTxn, Proof),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [EVTxn]) || M <- Miners],

    Me = self(),
    spawn(miner_ct_utils, election_check,
          [Validators, Validators,
           ValidatorAddrList ++ ?config(tagged_miner_addresses, Config),
           Me]),
    check_loop(180, Validators).

check_loop(0, _Miners) ->
    error(seen_timeout);
check_loop(N, Miners) ->
    %% TODO Describe main idea and method. What will send the mesgs? What is its API?
    %% TODO Need more transparent API, since the above isn't clear.
    %% TODO See if this function can be re-used in election_test
    receive
        seen_all ->
            ok;
        {not_seen, []} ->
            ok;
        {not_seen, Not} ->
            Miner = lists:nth(rand:uniform(length(Miners)), Miners),
            try
                Height = miner_ct_utils:height(Miner),
                {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 500),
                ct:pal("not seen: ~p height ~p epoch ~p", [Not, Height, Epoch])
            catch _:_ ->
                    ct:pal("not seen: ~p ", [Not]),
                    ok
            end,
            timer:sleep(100),
            check_loop(N - 1, Miners)
    after timer:seconds(30) ->
            error(message_timeout)
    end.


election_test(Config) ->
    %% TODO Describe main idea and method.
    %% TODO Break into subcomponents, it's very long and hard to reason about.
    BaseDir = ?config(base_dir, Config),
    %% get all the miners
    Miners = ?config(miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    Me = self(),
    spawn(miner_ct_utils, election_check, [Miners, Miners, AddrList, Me]),

    %% TODO Looks like copy-pasta - see if check_loop/2 can be used instead.
    fun Loop(0) ->
            error(seen_timeout);
        Loop(N) ->
            receive
                seen_all ->
                    ok;
                {not_seen, []} ->
                    ok;
                {not_seen, Not} ->
                    Miner = lists:nth(rand:uniform(length(Miners)), Miners),
                    try
                        Height = miner_ct_utils:height(Miner),
                        {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 500),
                        ct:pal("not seen: ~p height ~p epoch ~p", [Not, Height, Epoch])
                    catch _:_ ->
                            ct:pal("not seen: ~p ", [Not]),
                            ok
                    end,
                    timer:sleep(100),
                    Loop(N - 1)
            after timer:seconds(30) ->
                    error(message_timeout)
            end
    end(60),

    %% we've seen all of the nodes, yay.  now make sure that more than
    %% one election can happen.
    %% we wait until we have seen all miners hit an epoch of 3
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, all, 90),

    %% stop the first 4 miners
    TargetMiners = lists:sublist(Miners, 1, 4),
    Stop = miner_ct_utils:stop_miners(TargetMiners),

    ct:pal("stopped, waiting"),

    %% confirm miner is stopped
    ok = miner_ct_utils:wait_for_app_stop(TargetMiners, miner),

    %% delete the groups
    timer:sleep(1000),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),

    ct:pal("stopped and deleted"),

    %% start the stopped miners back up again
    miner_ct_utils:start_miners(Stop),

    %% second: make sure we're not making blocks anymore
    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    %% height might go up by one, but it should not go up by 5
    {_, false} = miner_ct_utils:wait_for_gte(height, Miners, Height + 5, any, 10),

    %% third: mint and submit the rescue txn, shrinking the group at
    %% the same time.

    Addresses = ?config(addresses, Config),
    NewGroup = lists:sublist(Addresses, 3, 4),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, HeadBlock} = ct_rpc:call(hd(Miners), blockchain, head_block, [HChain2]),

    NewHeight = blockchain_block:height(HeadBlock) + 1,
    ct:pal("new height is ~p", [NewHeight]),
    Hash = blockchain_block:hash_block(HeadBlock),

    Vars = #{?num_consensus_members => 4},

    {Priv, _Pub} = ?config(master_key, Config),

    Txn = blockchain_txn_vars_v1:new(Vars, 3),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    VarsTxn = blockchain_txn_vars_v1:proof(Txn, Proof),

    {ElectionEpoch, _EpochStart} = blockchain_block_v1:election_info(HeadBlock),
    ct:pal("current election epoch: ~p new height: ~p", [ElectionEpoch, NewHeight]),

    GrpTxn = blockchain_txn_consensus_group_v1:new(NewGroup, <<>>, Height, 0),

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
    ok = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain, self(), blockchain_swarm:tid()]),

    %% wait until height has increased by 3
    ok = miner_ct_utils:wait_for_gte(height, Miners, NewHeight + 2),

    %% check consensus and non consensus miners
    {NewConsensusMiners, NewNonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),

    %% stop some nodes and restart them to check group restore works
    StopList = lists:sublist(NewConsensusMiners, 2) ++ lists:sublist(NewNonConsensusMiners, 2),
    ct:pal("stop list ~p", [StopList]),
    Stop2 = miner_ct_utils:stop_miners(StopList),

    %% sleep a lil then start the nodes back up again
    timer:sleep(1000),

    miner_ct_utils:start_miners(Stop2),

    %% fourth: confirm that blocks and elections are proceeding
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, ElectionEpoch + 1).

election_multi_test(Config) ->
    %% TODO Describe main idea and method.
    %% TODO Break into subcomponents, it's very long and hard to reason about.
    BaseDir = ?config(base_dir, Config),
    %% get all the miners
    Miners = ?config(miners, Config),
    %% AddrList = ?config(tagged_miner_addresses, Config),
    Addresses = ?config(addresses, Config),
    {Priv, _Pub} = ?config(master_key, Config),

    %% we wait until we have seen all miners hit an epoch of 2
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 90),

    ct:pal("starting multisig attempt"),

    %% TODO Looks automatable - 5 unique things that aren't used uniquely:
    %{Privs, BinPubs} = (fun(N) ->
    %    Keys = [libp2p_crypto:generate_keys(ecc_compact) || {} <- lists:duplicate(N, {})],
    %    Privs = [Priv || #{secret := Priv} <- Keys],
    %    Pubs = [Pub || #{public := Pub} <- Keys],
    %    BinPubs = lists:map(fun libp2p_crypto:pubkey_to_bin/1, Pubs),
    %    {Privs, BinPubs}
    %)(5)
    #{secret := Priv1, public := Pub1} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv2, public := Pub2} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv3, public := Pub3} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv4, public := Pub4} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv5, public := Pub5} = libp2p_crypto:generate_keys(ecc_compact),
    BinPub1 = libp2p_crypto:pubkey_to_bin(Pub1),
    BinPub2 = libp2p_crypto:pubkey_to_bin(Pub2),
    BinPub3 = libp2p_crypto:pubkey_to_bin(Pub3),
    BinPub4 = libp2p_crypto:pubkey_to_bin(Pub4),
    BinPub5 = libp2p_crypto:pubkey_to_bin(Pub5),

    Txn7_0 = blockchain_txn_vars_v1:new(
               #{?use_multi_keys => true}, 2,
               #{multi_keys => [BinPub1, BinPub2, BinPub3, BinPub4, BinPub5]}),
    Proofs7 = [blockchain_txn_vars_v1:create_proof(P, Txn7_0)
               || P <- [Priv1, Priv2, Priv3, Priv4, Priv5]],
    Txn7_1 = blockchain_txn_vars_v1:multi_key_proofs(Txn7_0, Proofs7),
    Proof7 = blockchain_txn_vars_v1:create_proof(Priv, Txn7_1),
    Txn7 = blockchain_txn_vars_v1:proof(Txn7_1, Proof7),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn7]) || M <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?use_multi_keys, true),
    ct:pal("transitioned to multikey"),

    %% stop the first 4 miners
    TargetMiners = lists:sublist(Miners, 1, 4),
    Stop = miner_ct_utils:stop_miners(TargetMiners),

    %% confirm miner is stopped
    ok = miner_ct_utils:wait_for_app_stop(TargetMiners, miner),

    %% delete the groups
    timer:sleep(1000),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),

    %% start the stopped miners back up again
    miner_ct_utils:start_miners(Stop),

    NewAddrs =
        [begin
             Swarm = ct_rpc:call(Target, blockchain_swarm, swarm, [], 2000),
             [H|_] = LAs= ct_rpc:call(Target, libp2p_swarm, listen_addrs, [Swarm], 2000),
             ct:pal("addrs ~p ~p", [Target, LAs]),
             H
         end || Target <- TargetMiners],

    miner_ct_utils:pmap(
      fun(M) ->
              [begin
                   Sw = ct_rpc:call(M, blockchain_swarm, swarm, [], 2000),
                   ct_rpc:call(M, libp2p_swarm, connect, [Sw, Addr], 2000)
               end || Addr <- NewAddrs]
      end, Miners),

    %% second: make sure we're not making blocks anymore
    HChain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height1} = ct_rpc:call(hd(Miners), blockchain, height, [HChain1]),

    %% height might go up by one, but it should not go up by 5
    {_, false} = miner_ct_utils:wait_for_gte(height, Miners, Height1 + 5, any, 10),

    HeadAddress = ct_rpc:call(hd(Miners), blockchain_swarm, pubkey_bin, []),

    GroupTail = Addresses -- [HeadAddress],
    ct:pal("l ~p tail ~p", [length(GroupTail), GroupTail]),

    {NewHeight, HighBlock} =
        lists:max(
          [begin
               C = ct_rpc:call(M, blockchain_worker, blockchain, []),
               {ok, HB} = ct_rpc:call(M, blockchain, head_block, [C]),
               {blockchain_block:height(HB) + 1, HB}
           end || M <- Miners]),
    ct:pal("new height is ~p", [NewHeight]),

    Hash2 = blockchain_block:hash_block(HighBlock),
    {ElectionEpoch1, _EpochStart1} = blockchain_block_v1:election_info(HighBlock),
    GrpTxn2 = blockchain_txn_consensus_group_v1:new(GroupTail, <<>>, NewHeight, 0),

    RescueBlock2 =
        blockchain_block_v1:rescue(
                    #{prev_hash => Hash2,
                      height => NewHeight,
                      transactions => [GrpTxn2],
                      hbbft_round => NewHeight,
                      time => erlang:system_time(seconds),
                      election_epoch => ElectionEpoch1 + 1,
                      epoch_start => NewHeight}),

    EncodedBlock2 = blockchain_block:serialize(
                      blockchain_block_v1:set_signatures(RescueBlock2, [])),

    RescueSigs =
        [begin
             RescueSigFun2 = libp2p_crypto:mk_sig_fun(P),

             RescueSigFun2(EncodedBlock2)
         end
         || P <- [Priv1, Priv2, Priv3, Priv4, Priv5]],

    SignedBlock = blockchain_block_v1:set_signatures(RescueBlock2, [], RescueSigs),

    %% now that we have a signed block, cause one of the nodes to
    %% absorb it (and gossip it around)
    FirstNode = hd(Miners),
    SecondNode = lists:last(Miners),
    Chain1 = ct_rpc:call(FirstNode, blockchain_worker, blockchain, []),
    Chain2 = ct_rpc:call(SecondNode, blockchain_worker, blockchain, []),
    N = length(Miners),
    ct:pal("first node ~p second ~pN: ~p", [FirstNode, SecondNode, N]),
    ok = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain1, self(), blockchain_swarm:tid()]),
    ok = ct_rpc:call(SecondNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain2, self(), blockchain_swarm:tid()]),

    %% wait until height has increased
    case miner_ct_utils:wait_for_gte(height, Miners, NewHeight + 3, any, 30) of
        ok -> ok;
        _ ->
            [begin
                 Status = ct_rpc:call(M, miner, hbbft_status, []),
                 ct:pal("miner ~p, status: ~p", [M, Status])
             end
             || M <- Miners],
            error(rescue_group_made_no_progress)
    end.

group_change_test(Config) ->
    %% TODO Describe main idea and method.
    %% TODO Break into subcomponents, it's very long and hard to reason about.

    %% get all the miners
    Miners = ?config(miners, Config),
    BaseDir = ?config(base_dir, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(4, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),

    %% submit the transaction

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger1 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain1]),
    ?assertEqual({ok, totes_garb}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger1])),

    Vars = #{num_consensus_members => 7},

    {Priv, _Pub} = ?config(master_key, Config),

    Txn = blockchain_txn_vars_v1:new(Vars, 2, #{version_predicate => 2,
                                                unsets => [garbage_value]}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),

    %% wait for it to take effect
    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
         || Miner <- Miners],

    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    %% wait until height has increased by 10
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 10, all, 80),

    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([lists:last(Miners)]),

    Miners1 = Miners -- [Target],

    ct:pal("stopped target: ~p", [Target]),

    %% make sure we still haven't executed it
    C = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    L = ct_rpc:call(hd(Miners), blockchain, ledger, [C]),
    {ok, Members} = ct_rpc:call(hd(Miners), blockchain_ledger_v1, consensus_members, [L]),
    ?assertEqual(4, length(Members)),

    %% take a snapshot to load *before* the threshold is processed
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, _SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),

    %% alter the "version" for all of them that are up.
    lists:foreach(
      fun(Miner) ->
              ct_rpc:call(Miner, miner, inc_tv, [rand:uniform(4)]) %% make sure we're exercising the summing
      end, Miners1),

    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               NewVersion = ct_rpc:call(Miner, miner, test_version, [], 1000),
                               ct:pal("test version ~p ~p", [Miner, NewVersion]),
                               NewVersion > 1
                       end, Miners1)
             end),

    %% wait for the change to take effect
    Timeout = 200,
    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               C1 = ct_rpc:call(Miner, blockchain_worker, blockchain, [], Timeout),
                               L1 = ct_rpc:call(Miner, blockchain, ledger, [C1], Timeout),
                               case ct_rpc:call(Miner, blockchain, config, [num_consensus_members, L1], Timeout) of
                                   {ok, Sz} ->
                                       Versions =
                                           ct_rpc:call(Miner, blockchain_ledger_v1, cg_versions,
                                                       [L1], Timeout),
                                       ct:pal("size = ~p versions = ~p", [Sz, Versions]),
                                       Sz == 7;
                                   _ ->
                                       %% badrpc
                                       false
                               end
                       end, Miners1)
             end, 120, 1000),

    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{8}*/*", ""),
    [EightDir] = filelib:wildcard(BaseDir ++ "_*{8}*"),

    BlockchainR = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(hd(Miners), blockchain, genesis_block, [BlockchainR]),

    GenSer = blockchain_block:serialize(GenesisBlock),
    ok = file:make_dir(EightDir ++ "/update"),
    ok = file:write_file(EightDir ++ "/update/genesis", GenSer),

    %% clean out everything from the stopped node

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],

    MinerEnv = proplists:get_value(miner, TargetEnv),
    NewMinerEnv = [{update_dir, EightDir ++ "/update"} | MinerEnv],

    NewTargetEnv0 = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),
    NewTargetEnv = lists:keyreplace(miner, 1, NewTargetEnv0, {miner, NewMinerEnv}),

    %% restart it
    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    Swarm = ct_rpc:call(Target, blockchain_swarm, swarm, [], 2000),
    [H|_] = ct_rpc:call(Target, libp2p_swarm, listen_addrs, [Swarm], 2000),

    miner_ct_utils:pmap(
      fun(M) ->
              Sw = ct_rpc:call(M, blockchain_swarm, swarm, [], 2000),
              ct_rpc:call(M, libp2p_swarm, connect, [Sw, H], 2000)
      end, Miners1),

    Blockchain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger2 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain2]),
    ?assertEqual({error, not_found}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger2])),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height2} = ct_rpc:call(hd(Miners), blockchain, height, [HChain2]),

    ct:pal("post change miner ~p height ~p", [hd(Miners), Height2]),
    %% TODO: probably need to parameterize this via the delay
    ?assert(Height2 > Height + 10 + 5),

    %% do some additional checks to make sure that we restored across.

    ok = miner_ct_utils:wait_for_gte(height, [Target], Height2, all, 120),

    TC = ct_rpc:call(Target, blockchain_worker, blockchain, [], Timeout),
    TL = ct_rpc:call(Target, blockchain, ledger, [TC], Timeout),
    {ok, TSz} = ct_rpc:call(Target, blockchain, config, [num_consensus_members, TL], Timeout),
    ?assertEqual(TSz, 7),

    ok.

election_v3_test(Config) ->
    %% TODO Describe main idea and method.
    %% get all the miners
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2),

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{?election_version => 3,
             ?election_bba_penalty => 0.01,
             ?election_seen_penalty => 0.05},

    Txn = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?election_version, 3),

    {ok, Start} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    %% wait until height has increased by 10
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start + 10),

    %% get all blocks and check that they have the appropriate
    %% metadata

    [begin
         PrevBlock = miner_ct_utils:get_block(N - 1, hd(Miners)),
         Block = miner_ct_utils:get_block(N, hd(Miners)),
         ct:pal("n ~p s ~p b ~p", [N, Start, Block]),
         case N of
             _ when N < Start ->
                 ?assertEqual([], blockchain_block_v1:seen_votes(Block)),
                 ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block));
             %% skip these because we're not 100% certain when the var
             %% will become effective.
             _ when N < Start + 5 ->
                 ok;
             _ ->
                 Ts = blockchain_block:transactions(PrevBlock),
                 case lists:filter(fun(T) ->
                                           blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                                   end, Ts) of
                     [] ->
                         ?assertNotEqual([], blockchain_block_v1:seen_votes(Block)),
                         ?assertNotEqual(<<>>, blockchain_block_v1:bba_completion(Block));
                     %% first post-election block has no info
                     _ ->
                         ?assertEqual([<<>>], lists:usort([X || {_, X} <- blockchain_block_v1:seen_votes(Block)])),
                         ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block))
                 end
         end
     end
     || N <- lists:seq(2, Start + 10)],

    %% two should guarantee at least one consensus member is down but
    %% that block production is still happening
    StopList = lists:sublist(Miners, 7, 2),
    ct:pal("stop list ~p", [StopList]),
    _Stop = miner_ct_utils:stop_miners(StopList),

    {ok, Start2} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),
    %% try a skip to move past the occasional stuck group
    [ct_rpc:call(M, miner, hbbft_skip, []) || M <- lists:sublist(Miners, 1, 6)],

    ok = miner_ct_utils:wait_for_gte(height, lists:sublist(Miners, 1, 6), Start2 + 10, all, 120),

    [begin
         PrevBlock = miner_ct_utils:get_block(N - 1, hd(Miners)),
         Block = miner_ct_utils:get_block(N, hd(Miners)),
         ct:pal("n ~p s ~p b ~p", [N, Start, Block]),
         Ts = blockchain_block:transactions(PrevBlock),
         case lists:filter(fun(T) ->
                                   blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                           end, Ts) of
             [] ->
                 Seen = blockchain_block_v1:seen_votes(Block),
                 %% given the current code, BBA will always be 2f+1,
                 %% so there's no point in checking it other than
                 %% seeing that it is not <<>> or <<0>>
                 %% when we have something to check, this might be
                 %% helpful: lists:sum([case $; band (1 bsl N) of 0 -> 0; _ -> 1 end || N <- lists:seq(1, 7)]).
                 BBA = blockchain_block_v1:bba_completion(Block),

                 ?assertNotEqual([], Seen),
                 ?assertNotEqual(<<>>, BBA),
                 ?assertNotEqual(<<0>>, BBA),

                 Len = length(Seen),
                 ?assert(Len == 6 orelse Len == 5),

                 Votes = lists:usort([Vote || {_ID, Vote} <- Seen]),
                 [?assertNotEqual(<<127>>, V) || V <- Votes];
             %% first post-election block has no info
             _ ->
                 Seen = blockchain_block_v1:seen_votes(Block),
                 Votes = lists:usort([Vote || {_ID, Vote} <- Seen]),
                 ?assertEqual([<<>>], Votes),
                 ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block))
         end
     end
     %% start at +2 so we don't get a stale block that saw the
     %% stopping nodes.
     || N <- lists:seq(Start2 + 2, Start2 + 10)],

    ok.

snapshot_test(Config) ->
    %% TODO Describe main idea and method.
    %% get all the miners
    Miners0 = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    [Target | Miners] = Miners0,

    ct:pal("target ~p", [Target]),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 7),
    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([Target]),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),
    ?assert(is_binary(SnapshotHash)),
    ?assert(is_binary(SnapshotBlockHash)),
    ?assert(is_integer(SnapshotBlockHeight)),
    ct:pal("Snapshot hash is ~p at height ~p~n in block ~p",
           [SnapshotHash, SnapshotBlockHeight, SnapshotBlockHash]),

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],
    NewTargetEnv = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),

    ct:pal("new blockchain env ~p", [NewTargetEnv]),

    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    miner_ct_utils:wait_until(
      fun() ->
              try
                  undefined =/= ct_rpc:call(Target, blockchain_worker, blockchain, [])
              catch _:_ ->
                       false
              end
      end, 50, 200),

    ok = ct_rpc:call(Target, blockchain, reset_ledger_to_snap, []),


    ok = miner_ct_utils:wait_for_gte(height, Miners0, 25, all, 20),
    ok.


high_snapshot_test(Config) ->
    %% TODO Describe main idea and method.
    %% get all the miners
    Miners0 = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    [Target | Miners] = Miners0,

    ct:pal("target ~p", [Target]),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 7),
    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([Target]),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 70, all, 600),
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),
    ?assert(is_binary(SnapshotHash)),
    ?assert(is_binary(SnapshotBlockHash)),
    ?assert(is_integer(SnapshotBlockHeight)),
    ct:pal("Snapshot hash is ~p at height ~p~n in block ~p",
           [SnapshotHash, SnapshotBlockHeight, SnapshotBlockHash]),

    %% TODO: probably at this step we should delete all the blocks
    %% that the downed node has

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],
    NewTargetEnv = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),

    ct:pal("new blockchain env ~p", [NewTargetEnv]),

    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    timer:sleep(5000),
    ok = ct_rpc:call(Target, blockchain, reset_ledger_to_snap, []),

    ok = miner_ct_utils:wait_for_gte(height, Miners0, 80, all, 30),
    ok.




%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
