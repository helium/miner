-module(miner_blockchain_SUITE).

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

-compile([export_all]).

%% common test callbacks

all() -> [
          restart_test,
          dkg_restart_test,
          election_test,
          group_change_test,
          master_key_test,
          version_change_test,
          election_v3_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
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
        case TestCase of
            dkg_restart_test ->
                #{?election_interval => 10,
                  ?election_restart_interval => 99};
            _ ->
                #{}
        end,

    Vars = #{garbage_value => totes_garb,
             ?block_time => max(1500, BlockTime),
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
            [h3:from_geo({37.780586, -122.469470 + I/100}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitGen = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- lists:zip(Addresses, Locations)],
    Txns = InitialVars ++ InitialPayment ++ InitGen,

    DKGResults = miner_ct_utils:inital_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve),
    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    %% Get both consensus and non consensus miners
    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(ConsensusMiners), NonConsensusMiners),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 1),

    [   {master_key, {Priv, Pub}},
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config].

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).



restart_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    Miners = ?config(miners, Config),

    %% wait till the chain reaches height 2 for all miners
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 60),

    ok = miner_ct_utils:stop_miners(lists:sublist(Miners, 1, 2)),

    [begin
          ct_rpc:call(Miner, miner_consensus_mgr, cancel_dkg, [], 300)
     end
     || Miner <- lists:sublist(Miners, 3, 4)],

    %% just kill the consensus groups, we should be able to restore them
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{1,2}*", "/blockchain_swarm/groups/consensus_*"),

    ok = miner_ct_utils:start_miners(lists:sublist(Miners, 1, 2)),

    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 90),

    Heights =  miner_ct_utils:heights(Miners),

    {comment, Heights}.


dkg_restart_test(Config) ->
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

    miner_ct_utils:stop_miners(NCMiners ++ Stoppers, 60),
    ct:pal("stopping nc ~p stoppers ~p", [NCMiners, Stoppers]),

    %% wait until we're sure that the election is running
    ok = miner_ct_utils:wait_for_gte(height, lists:sublist(CMiners, 1, 4), Height + (Interval * 2), all, 180),

    %% stop half of the remaining miners
    Restarters = lists:sublist(CMiners, 1, 2),
    ct:pal("stopping restarters ~p", [Restarters]),
    miner_ct_utils:stop_miners(Restarters, 60),

    %% restore that half
    ct:pal("starting restarters ~p", [Restarters]),
    miner_ct_utils:start_miners(Restarters, 60),

    %% restore the last two
    ct:pal("starting blockers"),
    miner_ct_utils:start_miners(NCMiners ++ Stoppers, 60),

    %% make sure that we elect again
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, any, 90),

    %% make sure that we did the restore
    EndHeight = miner_ct_utils:height(FirstCMiner),
    ?assert(EndHeight < (Height + Interval + 99)).

election_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    %% get all the miners
    Miners = ?config(miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    Me = self(),
    spawn(miner_ct_utils, election_check, [Miners, Miners, AddrList, Me]),

    %% TODO - review this as it seems a lil flaky, sporadically hitting the timeouts during multiple test runs
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
                        Height = miner_ct_utils:height(Miner),
                        {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 500),
                        ct:pal("not seen: ~p height ~p epoch ~p", [Not, Height, Epoch])
                    catch _:_ ->
                            ct:pal("not seen: ~p ", [Not]),
                            ok
                    end,
                    timer:sleep(500),
                    Loop(N - 1)
            after timer:seconds(30) ->
                    error(timeout)
            end
    end(300),

    %% we've seen all of the nodes, yay.  now make sure that more than
    %% one election can happen.
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, any, 90),

    %% stop the first 4 miners
    TargetMiners = lists:sublist(Miners, 1, 4),
    miner_ct_utils:stop_miners(TargetMiners),

    %% confirm miner is stopped
    ok = miner_ct_utils:wait_for_app_stop(TargetMiners, miner),

    %% delete the groups
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{1,2,3,4}*", "/blockchain_swarm/groups/*"),

    %% start the stopped miners back up again
    miner_ct_utils:start_miners(TargetMiners),

    %% second: make sure we're not making blocks anymore
    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    %% wait until height has increased by 5
    ok = miner_ct_utils:wait_for_gte(height, Miners, 5),

    %% third: mint and submit the rescue txn, shrinking the group at
    %% the same time.

    Addresses = ?config(addresses, Config),
    NewGroup = lists:sublist(Addresses, 3, 4),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, HeadBlock} = ct_rpc:call(hd(Miners), blockchain, head_block, [HChain2]),
    NewHeight = blockchain_block:height(HeadBlock) + 1,
    Hash = blockchain_block:hash_block(HeadBlock),

    Vars = #{num_consensus_members => 4},

    {Priv, _Pub} = ?config(master_key, Config),

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
     _ = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [Swarm, SignedBlock, Chain, self()]),

    %% wait until height has increased by 5
    ok = miner_ct_utils:wait_for_gte(height, Miners, 5),

    %% check consensus and non consensus miners
    {NewConsensusMiners, NewNonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),

    %% stop some nodes and restart them to check group restore works
    StopList = lists:sublist(NewConsensusMiners, 2) ++ lists:sublist(NewNonConsensusMiners, 2),
    ct:pal("stop list ~p", [StopList]),
    miner_ct_utils:stop_miners(StopList),


    %% sleel a lil then start the nodes back up again
    timer:sleep(5000),

    miner_ct_utils:start_miners(StopList),

    %% fourth: confirm that blocks and elections are proceeding
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, ElectionEpoch + 1),

    ok.


group_change_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),
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

    %% wait until height has increased by 20
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 20, all, 80),

    %% make sure we still haven't executed it
    C = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    L = ct_rpc:call(hd(Miners), blockchain, ledger, [C]),
    {ok, Members} = ct_rpc:call(hd(Miners), blockchain_ledger_v1, consensus_members, [L]),
    ?assertEqual(4, length(Members)),

    %% alter the "version" for all of them.
    lists:foreach(
      fun(Miner) ->
              ct_rpc:call(Miner, miner, inc_tv, [rand:uniform(4)]) %% make sure we're exercising the summing
      end, Miners),

    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               NewVersion = ct_rpc:call(Miner, miner, test_version, [], 1000),
                               ct:pal("test version ~p ~p", [Miner, NewVersion]),
                               NewVersion > 1
                       end, Miners)
             end),

    %% wait for the change to take effect
    ok = miner_ct_utils:wait_for_in_consensus(Miners, 7),

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
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),

    %% baseline: chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn1_0),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1])
         || Miner <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, totes_goats_garb),

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

    %% wait until height has increased by 15
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start2 + 15),
    %% and then confirm the transaction took hold
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, totes_goats_garb),

    %% good master key

    Txn2_2 = blockchain_txn_vars_v1:key_proof(Txn2_1, KeyProof2),
    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_2])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    %% make sure old master key is no longer working

    Vars4 = #{garbage_value => goats_are_too_garb},
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 4),
    Proof4 = blockchain_txn_vars_v1:create_proof(Priv, Txn4_0),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
         || Miner <- Miners],

    %% wait until height has increased by 15
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start4 + 15),
    %% and then confirm the transaction took hold
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    %% double check that new master key works

    Vars5 = #{garbage_value => goats_always_win},
    Txn5_0 = blockchain_txn_vars_v1:new(Vars5, 4),
    Proof5 = blockchain_txn_vars_v1:create_proof(Priv2, Txn5_0),
    Txn5_1 = blockchain_txn_vars_v1:proof(Txn5_0, Proof5),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn5_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_always_win),

    ok.


version_change_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),


    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),

    %% baseline: old-style chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Proof = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars),
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, totes_goats_garb),

    %% switch chain version

    Vars2 = #{?chain_vars_version => 2},
    Proof2 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars2),
    Txn2_0 = blockchain_txn_vars_v1:new(Vars2, 3),
    Txn2_1 = blockchain_txn_vars_v1:proof(Txn2_0, Proof2),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_1])
         || Miner <- Miners],

    %% make sure that it has taken effect
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?chain_vars_version, 2),

    %% try a new-style txn change

    Vars3 = #{garbage_value => goats_are_not_garb},
    Txn3_0 = blockchain_txn_vars_v1:new(Vars3, 4),
    Proof3 = blockchain_txn_vars_v1:create_proof(Priv, Txn3_0),
    Txn3_1 = blockchain_txn_vars_v1:proof(Txn3_0, Proof3),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn3_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    %% make sure old style is now closed off.

    Vars4 = #{garbage_value => goats_are_too_garb},
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 5),
    Proof4 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars4),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
         || Miner <- Miners],

    %% wait until height has increased by 15
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start4 + 15),
    %% and then confirm the transaction took hold
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    ok.


election_v3_test(Config) ->
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
                         ?assertEqual([{0,<<>>}, {1,<<>>}, {2,<<>>}, {3,<<>>}, {4,<<>>},
                                       {5,<<>>}, {6,<<>>}],
                                      blockchain_block_v1:seen_votes(Block)),
                         ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block))
                 end
         end
     end
     || N <- lists:seq(2, Start + 10)],

    %% two should guarantee at least one consensus member is down but
    %% that block production is still happening
    StopList = lists:sublist(Miners, 7, 2),
    ct:pal("stop list ~p", [StopList]),
    miner_ct_utils:stop_miners(StopList),

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



%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------







