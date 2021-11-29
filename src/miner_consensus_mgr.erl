-module(miner_consensus_mgr).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

%% API
-export([
         start_link/1,

         initial_dkg/4,

         %% internal
         genesis_block_done/6,
         election_done/6,
         rescue_done/6,
         sign_artifact/2,

         %% info
         consensus_pos/0,
         in_consensus/0,
         dkg_status/0,
         txn_buf/0,

         group_predicate/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         current_dkgs = #{} :: #{{Height :: pos_integer(), Delay :: non_neg_integer()} => pid()},
         dkg_await :: undefined | {reference(), term()},
         initial_height = 1 :: non_neg_integer(),
         delay = 0 :: integer(),
         chain :: undefined | blockchain:blockchain(),
         started_groups = #{} :: #{{pos_integer(),non_neg_integer()} => pid()},
         active_group :: undefined | pid(),
         ag_monitor = make_ref() :: reference(),
         miner_monitor = make_ref() :: reference()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Args) ->
    %% The consensus manager can generate quite a bunch of garbage and then go to sleep
    %% which leaves the garbage uncollected. This option tells the gen_server to hibernate
    %% after 5 seconds of not receiving a message, which triggers a memory compaction.
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, [{hibernate_after, 5000}]).

dkg_status() ->
    case gen_server:call(?MODULE, dkg_group, 60000) of
        undefined -> not_running;
        Pid -> libp2p_group_relcast:handle_command(Pid, status)
    end.

txn_buf() ->
    case gen_server:call(?MODULE, txn_buf, 60000) of
        undefined -> not_running;
        Res -> Res
    end.


-spec consensus_pos() -> integer() | undefined.
consensus_pos() ->
    gen_server:call(?MODULE, consensus_pos).

-spec in_consensus() -> boolean().
in_consensus() ->
    gen_server:call(?MODULE, in_consensus).

initial_dkg(GenesisTransactions, Addrs, N, Curve) ->
    gen_server:call(?MODULE, {initial_dkg, GenesisTransactions, Addrs, N, Curve}, infinity).

-spec sign_artifact(Artifact :: binary(), any()) ->
                           {ok, libp2p_crypto:pubkey_bin(), binary()}.
sign_artifact(Artifact, _DeprecatedBackCompat) ->
    {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
    Signature = SignFun(Artifact),
    Address = libp2p_crypto:pubkey_to_bin(MyPubKey),
    {ok, Address, Signature}.

-spec genesis_block_done(GenesisBLock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         Members :: [libp2p_crypto:address()],
                         PrivKey :: tc_key_share:tc_key_share(),
                         Height :: pos_integer(),
                         Delay :: non_neg_integer()
                        ) -> ok.
genesis_block_done(GenesisBlock, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures,
                              Members, PrivKey, Height, Delay}, infinity).

-spec election_done(binary(), [{libp2p_crypto:pubkey_bin(), binary()}],
                    [libp2p_crypto:address()], tc_key_share:tc_key_share(),
                    pos_integer(), non_neg_integer()) -> ok.
election_done(Artifact, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:cast(?MODULE, {election_done, Artifact, Signatures,
                              Members, PrivKey, Height, Delay}).

rescue_done(Artifact, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:call(?MODULE, {rescue_done, Artifact, Signatures,
                              Members, PrivKey, Height, Delay}, infinity).

group_predicate("dkg" ++ _ = Name) ->
    try einfo() of
        #{election_height := ElectionHeight} ->
            case string:tokens(Name, "-") of
                [_Tag, _Hash, Height0, _Delay] ->
                    lager:debug("dkg pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
                    Height = list_to_integer(Height0),
                    Height < ElectionHeight;
                _ ->
                    false
            end;
        _ ->
            false
    catch _:_ ->
            false
    end;
group_predicate("consensus" ++ _ = Name) ->
    try einfo() of
        #{election_height := ElectionHeight} ->
            case string:tokens(Name, "_") of
                [_Tag, Height0, _Delay, _Hash] ->
                    lager:debug("con pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
                    Height = list_to_integer(Height0),
                    Height < ElectionHeight;
                _ ->
                    false
            end;
        _ ->
            false
    catch _:_ ->
            false
    end;
group_predicate("penalize" ++ _ = Name) ->
    try einfo() of
        #{election_height := ElectionHeight} ->
            case string:tokens(Name, "_") of
                [_Tag, Height0, _Delay, _Hash] ->
                    lager:debug("penalize pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
                    Height = list_to_integer(Height0),
                    Height < ElectionHeight;
                _ ->
                    false
            end;
        _ ->
            false
    catch _:_ ->
            false
    end;
group_predicate(_) ->
    false.

einfo() ->
    case blockchain_worker:blockchain() of
        undefined ->
            #{};
        Chain ->
            try
                blockchain_election:election_info(blockchain:ledger(Chain))
            catch _:_ ->
                    #{}
            end
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    ok = blockchain_event:add_handler(self()),
    erlang:send_after(timer:seconds(1), self(), monitor_miner),
    case  blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(timer:seconds(1), self(), chain_check),
            {ok, #state{}};
        Chain ->
            {ok, #state{chain = Chain}, 0}
    end.

%% in the call handlers, we wait for the dkg to return, and then once
%% it does, we communicate with the miner
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, Members, PrivKey, _Height, _Delay}, _From,
            State) ->
    GenesisBlock = blockchain_block:deserialize(BinaryGenesisBlock),
    SignedGenesisBlock = blockchain_block:set_signatures(GenesisBlock, Signatures),
    lager:notice("Got a signed genesis block: ~p", [SignedGenesisBlock]),

    case State#state.dkg_await of
        undefined -> ok;
        From -> gen_server:reply(From, ok)
    end,

    ok = blockchain_worker:integrate_genesis_block(SignedGenesisBlock),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    F = ((N - 1) div 3),
    {ok, BatchSize} = blockchain:config(?batch_size, Ledger),

    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),
    GroupArg = [miner_hbbft_handler, [Members,
                                      Pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1,
                                      []],
                [{create, true}]],
    Name = consensus_group_name(1, 0, Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(), Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("started initial hbbft group: ~p~n", [Group]),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    miner_hbbft_sidecar:set_group(Group),
    miner:start_chain(Group, Chain),

    case State#state.current_dkgs of
        #{ {1,0} := DKGGroup} ->
            stop_group(DKGGroup);
        _ ->
            ok
    end,
    {reply, ok, State#state{active_group = Group,
                            current_dkgs = #{},
                            chain = Chain}};

handle_call(txn_buf, _From, State) ->
    {reply, {ok, get_buf(State#state.active_group)}, State};
handle_call({rescue_done, _Artifact, _Signatures, Members, PrivKey, _Height, _Delay}, _From,
            State = #state{chain = Chain}) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:election_height(Ledger),
    lager:info("rescue election done at ~p", [Height]),

    {ok, N} = blockchain:config(num_consensus_members, Ledger),
    F = ((N - 1) div 3),
    {ok, BatchSize} = blockchain:config(batch_size, Ledger),
    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),

    {ok, #block_info_v2{hbbft_round=Round}} = blockchain:head_block_info(Chain),

    Buf = get_buf(State#state.active_group),

    GroupArg = [miner_hbbft_handler, [Members,
                                      Pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      Round + 1,
                                      Buf],
                [{create, true}]], % gets filled later
    %% while this won't reflect the actual height, it has to be deterministic
    Name = consensus_group_name(max(0, Height), 0, Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    Ref = erlang:monitor(process, Group),
    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
    %% adjust the height upwards, the rescue will be from one block
    %% above the present one.
    ok = miner:install_consensus(Group),
    lager:info("rescue stopping old group"),
    erlang:demonitor(State#state.ag_monitor, [flush]),
    stop_group(State#state.active_group),
    miner_hbbft_sidecar:set_group(Group),
    libp2p_group_relcast:handle_input(Group, {next_round, Round + 1, [], false}),

    {reply, ok, State#state{active_group = Group, ag_monitor = Ref}};
handle_call(dkg_group, _From, #state{current_dkgs = DKGs} = State) ->
    %% get the highest one
    case lists:reverse(lists:sort(maps:to_list(DKGs))) of
        [{_Ht, out}|_] ->
            {reply, undefined, State};
        [{_Ht, Group}|_] ->
            {reply, Group, State};
        [] ->
            {reply, undefined, State}
    end;
handle_call({initial_dkg, GenesisTransactions, Addrs, N, Curve}, From, State0) ->
    State = State0#state{initial_height = 1,
                         delay = 0},
    case do_initial_dkg(GenesisTransactions, Addrs, N, Curve, State) of
        {true, DKGState} ->
            lager:info("Waiting for DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {noreply, DKGState#state{dkg_await=From}};
        {false, NonDKGState} ->
            lager:info("Not running DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {reply, not_in, NonDKGState}
    end;
handle_call(consensus_pos, _From, State) ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, Members} = blockchain_ledger_v1:consensus_members(Ledger),
    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),
    {reply, Pos, State};
handle_call(in_consensus, _From, #state{chain=undefined, current_dkgs = DKGs} = State) ->
    Reply =
        case maps:find({1, 0}, DKGs) of
            error -> false;
            {ok, out} -> false;
            _ -> true
        end,
    {reply, Reply, State};
handle_call(in_consensus, _From, #state{chain = Chain} = State) ->
    %% there are three aspects to this:
    %%   1) are we in the consensus group as viewed by the chain
    %%   2) are we running an actual hbbft handler group in miner
    %%   3) does that miner group have a valid key to the larger group
    %% 2 and especially 3 are hard to do and harder to trust, so just
    %% do 1 for now
    try
        Ledger = blockchain:ledger(Chain),
        {ok, ConsensusGroup} = blockchain_ledger_v1:consensus_members(Ledger),
        MyAddr = blockchain_swarm:pubkey_bin(),
        {reply, lists:member(MyAddr, ConsensusGroup), State}
    catch _:_ ->
                {reply, false, State}
    end;
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast({election_done, _Artifact, Signatures, Members, PrivKey, Height, Delay},
            State = #state{chain = Chain,
                           current_dkgs = DKGs,
                           started_groups = Groups}) ->
    lager:info("election done at ~p delay ~p", [Height, Delay]),
    {ok, N} = blockchain:config(?num_consensus_members, blockchain:ledger(Chain)),
    F = ((N - 1) div 3),

    Proof = term_to_binary(Signatures, [compressed]),

    %% first we need to add ourselves to the chain for the existing
    %% group to validate
    {ok, ElectionHeight} = blockchain_ledger_v1:election_height(blockchain:ledger(Chain)),
    case ElectionHeight < Height of
        true ->
            Txn = blockchain_txn_consensus_group_v1:new(Members, Proof, Height, Delay),
            %% add this to the buffer of the local chain
            %% catch is because there might not be a sidecar running if
            %% we are currently not in the group
            catch miner_hbbft_sidecar:submit(Txn),
            %% send it to the txn mgr
            ok = blockchain_txn_mgr:submit(
                   Txn,
                   fun(Res) ->
                           case Res of
                               ok ->
                                   lager:info("Election successful, Height: ~p, Delay: ~p, Members: ~p, Proof: ~p",
                                              [Height, Delay, Members, Proof]);
                               {error, invalid} ->
                                   %% we don't need to print anything for these nonce-style failures.
                                   ok;
                               {error, Reason} ->
                                   lager:error("Election failed, Height: ~p, Members: ~p, Proof: ~p, Delay: ~p, Reason: ~p",
                                               [Height, Members, Proof, Delay, Reason])
                           end
                   end
                  );
        %% for a restore, don't bother.
        false -> ok
    end,
    {ok, BatchSize} = blockchain:config(?batch_size, blockchain:ledger(Chain)),
    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),

    GroupArg = [miner_hbbft_handler, [Members,
                                      Pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1, % gets set later
                                      []], % gets filled later
                [{create, true}]],
    %% while this won't reflect the actual height, it has to be deterministic
    Name = consensus_group_name(max(0, Height), Delay, Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),

    %% not sure what the correct error behavior here is?
    lager:info("checking that the hbbft group has successfully started"),
    started = wait_for_group(Group),

    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
    case maps:find({Height, Delay}, DKGs) of
        error -> ok;
        {ok, Grp} -> ok = libp2p_group_relcast:handle_command(Grp, mark_done)
    end,
    {noreply, State#state{started_groups = Groups#{{Height, Delay} => Group}}};
handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            #state{current_dkgs = DKGs} = State)
  when State#state.chain /= undefined ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),
    Now = erlang:system_time(seconds),
    case blockchain:get_block(Hash, State#state.chain) of
        {ok, Block} ->
            BlockHeight = blockchain_block:height(Block),
            lager:debug("got block at ~p sync ~p T ~p", [BlockHeight, Sync, (Now - blockchain_block:time(Block))]),
            case Sync andalso (Now - blockchain_block:time(Block) > 3600) of
                %% not sync, or recent sync
                false ->
                    lager:info("processing block height ~p", [BlockHeight]),
                    {_, EpochStart} = blockchain_block_v1:election_info(Block),

                    {Height, Delay, ElectionRunning} =
                        case next_election(EpochStart, ElectionInterval) of
                            infinity ->
                                {1, 0, false};
                            H ->
                                Diff = BlockHeight - H,
                                Delay0 = max(0, (Diff div RestartInterval) * RestartInterval),
                                ElectionRunning0 = H /= 1 andalso BlockHeight >= H,
                                {H, Delay0, ElectionRunning0}
                        end,

                    State2 =
                        %% here we only want to start a new election if: 1) it's valid to do so; 2)
                        %% we haven't done so already, and 3) it's the correct block to do so. The
                        %% reasoning for (3) is that we only set height/delay appropriately at that
                        %% height, and in the restore section.  If we're skipping the initial start
                        %% or restore for some reason, we cannot safely start here.
                        case ElectionRunning andalso
                            (not maps:is_key({Height, Delay}, DKGs)) andalso
                            BlockHeight == Height+Delay of
                            true ->
                                %% start the election running here
                                lager:info("starting new election at ~p+~p", [Height, Delay]),
                                initiate_election(Hash, Height,
                                                  State#state{delay = Delay,
                                                               initial_height = Height});
                            false ->
                                State#state{delay = Delay,
                                             initial_height = Height}
                        end,
                    Txns = blockchain_block:transactions(Block),
                    NewGroup = blockchain_election:has_new_group(Txns),
                    case blockchain_block_v1:is_rescue_block(Block) of
                        true ->
                            [Txn] =
                                lists:filter(
                                  fun(T) ->
                                          blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                                  end, Txns),
                            Members = blockchain_txn_consensus_group_v1:members(Txn),
                            MyAddress = blockchain_swarm:pubkey_bin(),
                            %% check if we're in the group
                            case lists:member(MyAddress, Members) of
                                true ->
                                    lager:info("Preparing to run rescue DKG: ~p", [Members]),
                                    State3 = rescue_dkg(Members, term_to_binary(Members), State2),
                                    {noreply, State3};
                                false ->
                                    lager:info("Not in rescue DKG: ~p", [Members]),
                                    {noreply, State2}
                            end;
                        false when NewGroup /= false andalso
                                   BlockHeight /= 1 ->
                            %% if we got a new group
                            {_, _, _Txn, {ElectionHeight, ElectionDelay} = EID} = NewGroup,
                            State3 =
                                case maps:find(EID, State#state.current_dkgs) of
                                    %% we're not in
                                    error ->
                                        %% if we've never heard of this one, try to restart the DKG,
                                        %% which we may have stopped
                                        case restart_dkg(ElectionHeight, ElectionDelay, State2) of
                                            no_dkg ->
                                                lager:info("stopping old group: election, no key"),
                                                erlang:demonitor(State2#state.ag_monitor, [flush]),
                                                stop_group(State2#state.active_group),
                                                miner:remove_consensus(),
                                                miner_hbbft_sidecar:set_group(undefined),
                                                State2#state{active_group = undefined};
                                            {ok, NewState} ->
                                                %% restart dkg takes care of the restart accounting
                                                NewState
                                        end;
                                    {ok, out} ->
                                        lager:info("stopping old group: election, elected out"),
                                        erlang:demonitor(State2#state.ag_monitor, [flush]),
                                        stop_group(State2#state.active_group),
                                        miner:remove_consensus(),
                                        miner_hbbft_sidecar:set_group(undefined),
                                        State2#state{current_dkgs =
                                                         maps:remove(EID, cleanup_groups(EID,
                                                                                         State2#state.current_dkgs, Ledger, true)),
                                                     started_groups = cleanup_groups(EID, State#state.started_groups, Ledger),
                                                     active_group = undefined};
                                    {ok, ElectionGroup} ->
                                        HBBFTGroup =
                                            case maps:find(EID, State#state.started_groups) of
                                                {ok, HGrp} ->
                                                    HGrp;
                                                error ->
                                                    lager:info("starting hbbft ~p+~p at block height ~p",
                                                               [ElectionHeight, ElectionDelay, BlockHeight]),
                                                    %% I want to just stop, but it's hard to untangle the code flow here.
                                                    {ok, HGrp} = start_hbbft(ElectionGroup, ElectionHeight,
                                                                             ElectionDelay, State2#state.chain),
                                                    HGrp
                                            end,
                                        %% make sure the new members are on the latest block so they know to start the round now
                                        {ok, NewConsensusAddrs} = blockchain_ledger_v1:consensus_members(blockchain:ledger(State#state.chain)),
                                        {ok, OldLedger} = blockchain:ledger_at(BlockHeight - 1, State#state.chain),
                                        {ok, OldConsensusAddrs} = blockchain_ledger_v1:consensus_members(OldLedger),
                                        Swarm = blockchain_swarm:swarm(),
                                        lists:foreach(
                                          fun(Member) ->
                                              spawn(fun() -> blockchain_fastforward_handler:dial(Swarm, State#state.chain, libp2p_crypto:pubkey_bin_to_p2p(Member)) end)
                                          end, blockchain_utils:shuffle(NewConsensusAddrs -- OldConsensusAddrs)),
                                        Round = blockchain_block:hbbft_round(Block),
                                        activate_hbbft(HBBFTGroup, State#state.active_group, State#state.ag_monitor, Round),
                                        Ref = erlang:monitor(process, HBBFTGroup),
                                        State2#state{current_dkgs = maps:remove(EID, cleanup_groups(EID, State2#state.current_dkgs, Ledger, true)),
                                                     started_groups = cleanup_groups(EID, State#state.started_groups, Ledger),
                                                     active_group = HBBFTGroup, ag_monitor = Ref}
                                end,
                            {noreply, State3#state{delay = 0}};
                        false when ElectionRunning ->
                            NextRestart = Height + RestartInterval + Delay,
                            case BlockHeight of
                                NewHeight when NewHeight >= NextRestart  ->
                                    lager:info("restart! h ~p next ~p", [NewHeight, NextRestart]),
                                    %% restart the dkg
                                    State3 = restart_election(State2, Hash, Height),
                                    {noreply, State3};
                                NewHeight ->
                                    lager:info("restart? h ~p next ~p", [NewHeight, NextRestart]),
                                    {noreply, State2}
                            end;
                        _ ->
                            {noreply, State2}
                    end;
                %% non-recent sync block, ignore
                true ->
                    {noreply, State}
            end;
        _Error ->
            lager:warning("didn't get gossiped block: ~p", [_Error]),
            {noreply, State}
    end;
handle_info({blockchain_event, {add_block, _Hash, _Sync, _Ledger}}, State) ->
    case State#state.chain of
        undefined ->
            Chain = blockchain_worker:blockchain(),
            {noreply, State#state{chain = Chain}};
        _ ->
            {noreply, State}
    end;
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    %% check if we're in the consensus group
    self() ! timeout,
    {noreply, State#state{chain = NC}};
handle_info({blockchain_event, {integrate_genesis_block, _Hash}}, State = #state{chain=undefined}) ->
    %% check if we're in the consensus group
    self() ! timeout,
    Chain = blockchain_worker:blockchain(),
    {noreply, State#state{chain=Chain}};
%% we had a chain to start with, so check restore state
handle_info(timeout, State) ->
    try
        {ok, #block_info_v2{height=StartHeight, hbbft_round=Round}} = blockchain:head_block_info(State#state.chain),

        lager:info("try cold start consensus group at ~p", [StartHeight]),

        Chain = blockchain_worker:blockchain(),

        case application:get_env(blockchain, follow_mode, false) of
            true -> throw(follow_mode_enabled);
            false -> ok
        end,
        Ledger = blockchain:ledger(Chain),
        {ok, N} = blockchain:config(?num_consensus_members, Ledger),
        {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
        {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),

        F = ((N - 1) div 3),

        case blockchain_ledger_v1:consensus_members(Ledger) of
            {error, _} ->
                lager:info("not restoring consensus group: no chain"),
                {noreply, State};
            {ok, ConsensusAddrs} ->
                %% check if we're a consensus group member and do restore actions
                #{election_height := ElectionHeight,
                  start_height := EpochStart,
                  election_delay := ElectionDelay} =
                    blockchain_election:election_info(Ledger),
                NextElection = next_election(EpochStart, ElectionInterval),
                RestoreState =
                    case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
                        true ->
                            lager:info("in group, trying to restore"),
                            {ok, BlockHeight} = blockchain:height(Chain),
                            Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
                            Name = consensus_group_name(ElectionHeight, ElectionDelay, ConsensusAddrs),
                            {ok, BatchSize} = blockchain:config(?batch_size, Ledger),
                            %% we intentionally don't use create here, because
                            %% this is a restore.
                            GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
                                                              Pos,
                                                              N,
                                                              F,
                                                              BatchSize,
                                                              undefined,
                                                              Chain]],
                            %% while this won't reflect the actual height, it has to be deterministic
                            lager:info("restoring consensus group ~p", [Name]),
                            {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                                                 Name,
                                                                 libp2p_group_relcast, GroupArg),
                            case wait_for_group(Group) of
                                started ->
                                    %% no need for active group to stop
                                    activate_hbbft(Group, undefined, make_ref(), Round),
                                    Ref = erlang:monitor(process, Group),
                                    State#state{active_group = Group, ag_monitor = Ref};
                                {error, cannot_start} ->
                                    lager:info("didn't restore consensus group, missing"),
                                    ok = libp2p_swarm:remove_group(blockchain_swarm:tid(), Name),
                                    case BlockHeight < (ElectionHeight+ElectionDelay+10) of
                                        true ->
                                            restore_dkg(ElectionHeight, ElectionDelay, Round, State);
                                        _ ->
                                            State
                                    end;
                                {error, Reason} ->
                                    lager:info("didn't restore consensus group: ~p", [Reason]),
                                    ok = libp2p_swarm:remove_group(blockchain_swarm:tid(), Name),
                                    State
                            end;
                        false ->
                            State
                    end,
                %% need to check if an election should already have been started
                case NextElection =< StartHeight of
                    true ->
                        Diff = StartHeight - NextElection,
                        Delay = max(0, (Diff div RestartInterval) * RestartInterval),
                        lager:info("try to start or restore the election group next ~p start ~p delay ~p",
                                   [NextElection, StartHeight, Delay]),
                        State1 = RestoreState#state{initial_height = NextElection,
                                                    delay = Delay},

                        Election = NextElection + Delay,
                        {ok, Hash} = blockchain:get_block_hash(Election, Chain),
                        State2 = initiate_election(Hash, NextElection, State1),
                        {noreply, State2};
                    _ ->
                        {noreply, RestoreState}
                end
        end
    catch C:E:S ->
            %% unknown errors in here should not put the node into an
            %% unrepairable state.
            lager:warning("crash during restore process, going to idle state ~p:~p ~p",
                          [C, E, S]),
            {noreply, State}

    end;
handle_info({'DOWN', MinerRef, process, _MinerPid, _Reason},
            #state{miner_monitor = MinerRef} = State) ->
    self() ! monitor_miner,
    {noreply, State};
handle_info(chain_check, State) ->
    State1 =
        case blockchain_worker:blockchain() of
            undefined ->
                erlang:send_after(timer:seconds(1), self(), chain_check),
                State;
            Chain ->
                self() ! timeout,
                State#state{chain = Chain}
        end,
    {noreply, State1};
handle_info(monitor_miner, #state{active_group = Group} = State) ->
    %% we've seen cases where the miner will think that it's out of consensus because
    %% miner process has crashed, but the group is still running, just not participating
    %% correctly.  this makes sure that the miner gets the group reinstalled on restart
    MinerPid = whereis(miner),
    case is_pid(MinerPid) andalso is_process_alive(MinerPid) of
        true ->
            %% re-establish the reference, waiting for a little while if needed
            NewRef = erlang:monitor(process, MinerPid),
            %% reinstall the group so that we participate, if there's a group
            case Group of
                undefined ->
                    ok;
                _ ->
                    ok = miner:install_consensus(Group)
            end,
            {noreply, State#state{miner_monitor = NewRef}};
        false ->
            erlang:send_after(timer:seconds(1), self(), monitor_miner),
            {noreply, State}
    end;
handle_info({'DOWN', OldRef, process, _GroupPid, _Reason},
            #state{ag_monitor = OldRef, active_group = OldGroup,
                   chain = Chain} = State) ->
    lager:info("active group ~p went down: ~p", [OldGroup, _Reason]),
    %% try to restart
    Ledger = blockchain:ledger(Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),

    F = ((N - 1) div 3),
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    #{election_height := ElectionHeight,
      election_delay := ElectionDelay} =
        blockchain_election:election_info(Ledger),
    {ok, #block_info_v2{hbbft_round=Round}} = blockchain:head_block_info(Chain),
    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
    Name = consensus_group_name(ElectionHeight, ElectionDelay, ConsensusAddrs),
    {ok, BatchSize} = blockchain:config(?batch_size, Ledger),
    %% we intentionally don't use create here
    GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
                                      Pos,
                                      N,
                                      F,
                                      BatchSize,
                                      undefined,
                                      Chain]],
    lager:info("restoring down consensus group ~p", [Name]),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    case wait_for_group(Group) of
        started ->
            Ref = erlang:monitor(process, Group),
            %% no need for old group, this is a response to one dying
            activate_hbbft(Group, undefined, make_ref(), Round),
            {noreply, State#state{active_group = Group, ag_monitor = Ref}};
        {error, Reason} ->
            %% die on failure
            lager:info("didn't restore consensus group: ~p", [Reason]),
            {stop, Reason, State}
    end;
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, #state{active_group = Active,
                          ag_monitor = Ref,
                          started_groups = Started,
                          current_dkgs = Current}) ->
    lager:info("starting termination stops"),
    erlang:demonitor(Ref, [flush]),
    stop_group(Active),
    maps:map(fun(_, G) -> stop_group(G) end, Started),
    maps:map(fun(_, G) -> stop_group(G) end, Current),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

initiate_election(Hash, Height, #state{delay = Delay} = State) ->
    Chain = State#state.chain,
    {ok, Ledger} = blockchain:ledger_at(Height + Delay, Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    lager:info("hash ~p height ~p delay ~p", [Hash, Height, Delay]),
    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    Artifact = term_to_binary(ConsensusAddrs),

    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_artifact},
                         election_done, N, Curve, true, State#state{initial_height = Height}),

    limit_dkgs(State1).

restart_election(#state{delay = Delay,
                        chain=Chain} = State, Hash, Height) ->

    {ok, Ledger} = blockchain:ledger_at(Height + Delay, Chain),
    lager:warning("restarting election at ~p delay ~p", [Height, Delay]),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    case length(ConsensusAddrs) == N of
        true ->
            Artifact = term_to_binary(ConsensusAddrs),
            {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_artifact},
                                 election_done, N, Curve, true, State#state{delay = Delay}),
            limit_dkgs(State1);
        false ->
            lager:warning("issue generating new group.  skipping restart"),
            State
    end.

-spec limit_dkgs(State :: #state{}) -> #state{}.
limit_dkgs(#state{current_dkgs = CurrentDKGs} = State) ->
    Ledger = blockchain:ledger(State#state.chain),
    Limit = case blockchain:config(?election_restart_interval_range, Ledger) of
                {ok, IR} -> IR + 1;
                _ -> 2
            end,
    Sz = maps:size(CurrentDKGs),
    lager:debug("size ~p limit ~p", [Sz, Limit]),
    case Sz > Limit of
        false ->
            State;
        true ->
            %% this generates the list in oldest to newest order
            DKGList = lists:sort(maps:to_list(CurrentDKGs)),
            {Stop0, Rem} = lists:split(Sz - Limit, DKGList),
            {_, Stop} = lists:unzip(Stop0),
            lists:foreach(fun(G) -> maybe_penalize(G, Ledger) end, Stop),
            lists:foreach(fun stop_group/1, Stop),
            State#state{current_dkgs = maps:from_list(Rem)}
    end.

rescue_dkg(Members, Artifact, State) ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, Curve} = blockchain:config(dkg_curve, Ledger),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),

    {_, State1} = do_dkg(Members, Artifact, {?MODULE, sign_artifact},
                         rescue_done, length(Members), Curve, true, % I think length is OK only here
                         State#state{initial_height = Height,
                                     delay = 0}),
    State1.

%%% restart dkg is called when we haven't heard of an election, meaning that a) we might have
%%% restarted since the election started, or b) we might have shut the dkg for it down in a race
%%% with the transaction.  in either case, we may need to restart the dkg, start the hbbft group
-spec restart_dkg(Height :: non_neg_integer(), Delay :: non_neg_integer(), State :: #state{}) ->
          no_dkg | {ok, #state{}}.
restart_dkg(Height, Delay, State) ->
    EID = {Height, Delay},
    Chain = State#state.chain,
    {ok, Ledger} = blockchain:ledger_at(Height + Delay, Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    {ok, #block_info_v2{hash=Hash}} = blockchain:get_block_info(Height + Delay, Chain),

    {ok, #block_info_v2{hbbft_round=Round}} = blockchain:head_block_info(Chain),

    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    Artifact = term_to_binary(ConsensusAddrs),

    case do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_artifact},
                election_done, N, Curve,
                false, % do not create this if it doesn't exist
                #state{initial_height = Height,  % blank state woo
                       delay = Delay,
                       chain = Chain}) of
        {false, _} ->
            no_dkg;
        {_, DKGState} ->
            {ok, DKGGroup} = maps:find({Height, Delay}, DKGState#state.current_dkgs),
            case start_hbbft(DKGGroup, Height, Delay, Chain) of
                {ok, HBBFTGroup} ->
                    activate_hbbft(HBBFTGroup, State#state.active_group, State#state.ag_monitor, Round),
                    Ref = erlang:monitor(process, HBBFTGroup),
                    {ok, State#state{current_dkgs = maps:remove(EID, cleanup_groups(EID, State#state.current_dkgs, Ledger, true)),
                                     started_groups = cleanup_groups(EID, State#state.started_groups, Ledger),
                                     active_group = HBBFTGroup, ag_monitor = Ref}};
                {error, _} -> no_dkg
            end
    end.

%%% restore dkg is what is called when the node restarts, it needs to return a whole state,
%%% potentially with consensus group
restore_dkg(Height, Delay, Round, State) ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    {ok, BatchSize} = blockchain:config(?batch_size, Ledger),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),
    Artifact = term_to_binary(ConsensusAddrs),
    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_artifact},
                         election_done, N, Curve, false,
                         State#state{initial_height = Height,
                                     delay = Delay}),
    DKGGroup = maps:get({Height, Delay}, State1#state.current_dkgs),
    case wait_for_group(DKGGroup) of
        started ->
            %% this is only called when we cannot start the current consensus
            %% group on restore, so should be safe to do create.
            F = ((N - 1) div 3),
            case libp2p_group_relcast:handle_command(DKGGroup, get_info) of
                {ok, PrivKey, Members} ->
                    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),
                    GroupArg = [miner_hbbft_handler, [Members,
                                                      Pos,
                                                      N,
                                                      F,
                                                      BatchSize,
                                                      PrivKey,
                                                      State#state.chain,
                                                      1, % gets set later
                                                      []],
                                [{create, true}]],
                    %% while this won't reflect the actual height, it has to be deterministic
                    Name = consensus_group_name(max(0, Height), Delay, Members),
                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                                         Name,
                                                         libp2p_group_relcast, GroupArg),

                    %% not sure what the correct error behavior here is?
                    lager:info("checking that the hbbft group has successfully started"),
                    started = wait_for_group(Group),
                    lager:info("restore start group ~p ~p in pos ~p", [Name, Group, Pos]),
                    activate_hbbft(Group, undefined, make_ref(), Round),
                    #state{current_dkgs = DKGs} = State1,
                    {DKGGroup, DKGs1} = maps:take({Height, Delay}, DKGs),
                    State1#state{active_group = Group,
                                 current_dkgs = DKGs1};
                {error, not_done} ->
                    lager:info("no privkey, can't try to restore HBBFT"),
                    State1
            end;
        {error, _} ->
            lager:info("no election group to restore"),
            State1
    end.

do_initial_dkg(GenesisTransactions, Addrs, N, Curve, State) ->
    lager:info("do initial"),
    SortedAddrs = lists:sort(Addrs),

    ConsensusAddrs = lists:sublist(SortedAddrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [animalize(ConsensusAddrs)]),
    %% in the consensus group, run the dkg
    GenesisBlockTransactions = GenesisTransactions ++
        [blockchain_txn_consensus_group_v1:new(ConsensusAddrs, <<>>, 1, 0)],
    Artifact = blockchain_block:serialize(blockchain_block:new_genesis_block(GenesisBlockTransactions)),
    do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_artifact},
           genesis_block_done, N, Curve, true, State).

do_dkg(Addrs, Artifact, Sign, Done, N, _Curve, Create,
       State=#state{initial_height = Height,
                    delay = Delay,
                    current_dkgs = DKGs,
                    chain = Chain}) ->
    lager:info("N: ~p", [N]),
    F = ((N-1) div 3),
    lager:info("F: ~p", [F]),
    ConsensusAddrs = lists:sublist(Addrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [animalize(ConsensusAddrs)]),
    MyAddress = blockchain_swarm:pubkey_bin(),
    lager:info("MyAddress: ~p", animalize([MyAddress])),
    case lists:member(MyAddress, ConsensusAddrs) of
        true ->
            lager:info("Preparing to run DKG #~p at height ~p ", [Delay, Height]),
            Pos = miner_util:index_of(MyAddress, ConsensusAddrs),

            Swarm = blockchain_swarm:swarm(),

            %% To ensure the DKG can actually complete, attempt to fastforward all the
            %% DKG peers so they all know they're in the newly proposed consensus group
            lists:foreach(
              fun(Member) ->
                  spawn(fun() -> blockchain_fastforward_handler:dial( Swarm, Chain, libp2p_crypto:pubkey_bin_to_p2p(Member)) end)
              end, blockchain_utils:shuffle(ConsensusAddrs -- [MyAddress])),

            %% make a simple hash of the consensus members
            DKGHash = base58:binary_to_base58(crypto:hash(sha, term_to_binary(ConsensusAddrs))),
            DKGCount = "-" ++ integer_to_list(Height),
            DKGDelay = "-" ++ integer_to_list(Delay),
            %% This DKG group name should be unique for the lifetime of a chain
            DKGGroupName = "dkg-"++DKGHash++DKGCount++DKGDelay,

            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            Pos,
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Artifact,
                                            Sign,
                                            {?MODULE, Done}, list_to_binary(DKGGroupName),
                                            Height,
                                            Delay],
                       [{create, Create}]],

            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                                    DKGGroupName,
                                                    libp2p_group_relcast,
                                                    GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            lager:info("height ~p delay ~p Address: ~p, ConsensusWorker pos: ~p, Group name ~p",
                       [Height, Delay, MyAddress, Pos, DKGGroupName]),
            {true, State#state{current_dkgs = DKGs#{{Height, Delay} => DKGGroup}}};
        false ->
            lager:info("not in DKG this round at height ~p ~p", [Height, Delay]),
            {false, State#state{current_dkgs = DKGs#{{Height, Delay} => out}}}
    end.

start_hbbft(DKG, Height, Delay, Chain) ->
    start_hbbft(DKG, Height, Delay, Chain, 12).

start_hbbft(DKG, Height, Delay, Chain, Retries) ->
    {ok, Ledger} = blockchain:ledger_at(Height + Delay, Chain),
    {ok, BatchSize} = blockchain:config(?batch_size, Ledger),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    F = ((N - 1) div 3),
    case libp2p_group_relcast:handle_command(DKG, get_info) of
        {ok, PrivKey, Members} ->
            Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),
            GroupArg = [miner_hbbft_handler, [Members,
                                              Pos,
                                              N,
                                              F,
                                              BatchSize,
                                              PrivKey,
                                              Chain,
                                              1, % gets set later
                                              []], % gets filled later
                        [{create, true}]],
            %% while this won't reflect the actual height, it has to be deterministic
            Name = consensus_group_name(max(0, Height), Delay, Members),
            {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                                 Name,
                                                 libp2p_group_relcast, GroupArg),

            %% not sure what the correct error behavior here is?
            lager:info("checking that the hbbft group has successfully started"),
            started = wait_for_group(Group),
            ok = libp2p_group_relcast:handle_command(DKG, mark_done),

            lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
            {ok, Group};
        {error, not_done} ->
            case Retries of
                0 ->
                    {error, not_done};
                _ ->
                    %% try a little harder to wait for the end.
                    timer:sleep(5000),
                    start_hbbft(DKG, Height, Delay, Chain, Retries - 1)
            end
    end.

activate_hbbft(Group, PrevGroup, PrevRef, Round) ->
    Buf = get_buf(PrevGroup),
    set_buf(Group, Buf),
    erlang:demonitor(PrevRef, [flush]),
    stop_group(PrevGroup),
    miner_hbbft_sidecar:set_group(Group),
    libp2p_group_relcast:handle_input(Group, {next_round, Round + 1, [], false}),
    miner:install_consensus(Group).

consensus_group_name(Height, fallback, Members) ->
    lists:flatten(io_lib:format("consensus_~b_~b", [Height, erlang:phash2(Members)]));
consensus_group_name(Height, Delay, Members) ->
    lists:flatten(io_lib:format("consensus_~b_~b_~b", [Height, Delay, erlang:phash2(Members)])).

penalize_group_name(Height, Delay, Members) ->
    lists:flatten(io_lib:format("penalize_~b_~b_~b", [Height, Delay, erlang:phash2(Members)])).

animalize(L) ->
    lists:map(fun(X0) ->
                      X = libp2p_crypto:bin_to_b58(X0),
                      {ok, N} = erl_angry_purple_tiger:animal_name(X),
                      N
              end,
              L).

%% the retry total time here is 6s per retry.  I've seen stuff locked
%% for over 30, so increasing the timeout to 90s.
wait_for_group(Group) ->
    wait_for_group(Group, 25).

wait_for_group(_Group, 0) ->
    {error, could_not_check};
wait_for_group(Group, Retries) ->
    try libp2p_group_relcast:status(Group) of
        started ->
            started;
        cannot_start ->
            {error, cannot_start};
        not_started ->
            timer:sleep(500),
            wait_for_group(Group, Retries - 1)
    catch C:E ->
            %% we've probably crashed because of a timeout, give it a
            %% bit more time
            lager:warning("status call failed: ~p:~p", [C, E]),
            timer:sleep(1000),
            wait_for_group(Group, Retries - 1)
    end.

set_buf(ConsensusGroup, Buf) ->
    case ConsensusGroup of
        P when is_pid(P) ->
            case is_process_alive(P) of
                true ->
                    ok = libp2p_group_relcast:handle_command(P, {set_buf, Buf});
                _ ->
                    {error, no_group}
            end;
        _ ->
            {error, no_group}
    end.

stop_group(undefined) ->
    ok;
stop_group(out) ->
    ok;
stop_group(Pid) ->
    spawn(fun() ->
                  %% tell the group it's allowed to stop
                  catch libp2p_group_relcast:handle_command(Pid, mark_done),
                  %% actually tell the group to stop
                  catch libp2p_group_relcast:handle_command(Pid, stop)
          end),
    ok.

maybe_penalize(undefined, _) ->
    ok;
maybe_penalize(out, _) ->
    ok;
maybe_penalize(Pid, Ledger) ->
    case blockchain:config(?election_version, Ledger) of
        {ok, V} when V >= 5 ->
            spawn(fun() ->
                          case libp2p_group_relcast:handle_command(Pid, final_status) of
                              {ok, {PrivKey, Signatures, Members, Delay, Height}} ->
                                  Name = penalize_group_name(Height, Delay, Members),
                                  %% we intentionally don't use create here
                                  GroupArg = [miner_dkg_penalty_handler, [Members,
                                                                          PrivKey,
                                                                          Signatures,
                                                                          Delay,
                                                                          Height],
                                              [{create, true}]],
                                  lager:info("starting penalize group ~p", [Name]),
                                  {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:tid(),
                                                                       Name,
                                                                       libp2p_group_relcast, GroupArg),
                                  libp2p_group_relcast:handle_input(Group, start),
                                  %% TODO we need to tell the consensus manager about this group?
                                  spawn(fun() ->
                                                Timeout = application:get_env(miner, penalty_group_timeout, 120),
                                                timer:sleep(timer:seconds(Timeout)),
                                                catch libp2p_group_relcast:handle_command(Group, stop)
                                        end),
                                  Group;
                              _ ->
                                  ok
                          end
                  end),
            ok;
        _ ->
            ok
    end.

get_buf(ConsensusGroup) ->
    case ConsensusGroup of
        P when is_pid(P) ->
            case is_process_alive(P) of
                true ->
                    case catch libp2p_group_relcast:handle_command(P, get_buf) of
                        {ok, B} ->
                            B;
                        _ ->
                            %% S = libp2p_group_relcast_sup:server(P),
                            %% lager:info("what the hell ~p", [erlang:process_info(S, current_stacktrace)]),
                            %% lager:info("what the hell ~p", [sys:get_state(S)]),
                            []
                    end;
                _ ->
                    []
            end;
        _ ->
            []
    end.

next_election(_Base, Interval) when is_atom(Interval) ->
    infinity;
next_election(Base, Interval) ->
    Base + Interval.

cleanup_groups(EID, Groups, Ledger) ->
    cleanup_groups(EID, Groups, Ledger, false).

cleanup_groups({Start, _Delay} = EID, Groups, Ledger, Retain) ->
    lager:info("cleaning up old groups on election of ~p", [EID]),
    maps:fold(
      %% this is the new active group. remove but don't stop
      fun(K, _V, G) when K == EID andalso Retain == false ->
              lager:info("ignoring new group"),
              G;
         %% group from same or older start height, stop and remove
         ({S, _D} = E, V, G) when S =< Start ->
              lager:info("stopping group ~p ~p", [E, V]),
              %% retain = true means we're cleaning up stale DKGs, and S == Start means that they're
              %% from this election cycle (older ones will have been successful).
              case Retain andalso S == Start of
                  true ->
                      maybe_penalize(V, Ledger);
                  _ -> ok
              end,
              stop_group(V),
              G;
         (K, V, G) ->
              G#{K => V}
      end,
      #{},
      Groups).
