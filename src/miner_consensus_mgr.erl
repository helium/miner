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
         sign_genesis_block/2,

         %% info
         consensus_pos/0,
         in_consensus/0,
         dkg_status/0,

         group_predicate/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         current_dkgs = #{} :: #{{pos_integer(),non_neg_integer()} => pid()},
         dkg_await :: undefined | {reference(), term()},
         initial_height = 1 :: non_neg_integer(),
         delay = 0 :: integer(),
         chain :: undefined | blockchain:blockchain(),
         cancel_dkgs = #{} :: #{pos_integer() => pid()},
         started_groups = #{} :: #{{pos_integer(),non_neg_integer()} => pid()},
         active_group :: undefined | pid()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

dkg_status() ->
    case gen_server:call(?MODULE, dkg_group, 60000) of
        undefined -> not_running;
        Pid -> libp2p_group_relcast:handle_command(Pid, status)
    end.

-spec consensus_pos() -> integer() | undefined.
consensus_pos() ->
    gen_server:call(?MODULE, consensus_pos).

-spec in_consensus() -> boolean().
in_consensus() ->
    gen_server:call(?MODULE, in_consensus).

initial_dkg(GenesisTransactions, Addrs, N, Curve) ->
    gen_server:call(?MODULE, {initial_dkg, GenesisTransactions, Addrs, N, Curve}, infinity).

-spec sign_genesis_block(GenesisBlock :: binary(), PrivKey :: tpke_privkey:privkey()) ->
                                {ok, libp2p_crypto:pubkey_bin(), binary()}.
sign_genesis_block(GenesisBlock, PrivKey) ->
    gen_server:call(?MODULE, {sign_genesis_block, GenesisBlock, PrivKey}).

-spec genesis_block_done(GenesisBLock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         Members :: [libp2p_crypto:address()],
                         PrivKey :: tpke_privkey:privkey(),
                         Height :: pos_integer(),
                         Delay :: non_neg_integer()
                        ) -> ok.
genesis_block_done(GenesisBlock, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures,
                              Members, PrivKey, Height, Delay}, infinity).

-spec election_done(binary(), [{libp2p_crypto:pubkey_bin(), binary()}],
                    [libp2p_crypto:address()], tpke_privkey:privkey(),
                    pos_integer(), non_neg_integer()) -> ok.
election_done(Artifact, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:call(?MODULE, {election_done, Artifact, Signatures,
                              Members, PrivKey, Height, Delay}, infinity).

rescue_done(Artifact, Signatures, Members, PrivKey, Height, Delay) ->
    gen_server:call(?MODULE, {rescue_done, Artifact, Signatures,
                              Members, PrivKey, Height, Delay}, infinity).

group_predicate("dkg" ++ _ = Name) ->
    try einfo() of
        #{election_height := ElectionHeight} ->
            case string:tokens(Name, "-") of
                [_Tag, _Hash, Height0, _Delay] ->
                    lager:info("dkg pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
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
                    lager:info("con pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
                    Height = list_to_integer(Height0),
                    Height < ElectionHeight;
                [_Tag, Height0, _Hash] ->
                    lager:info("con pred ~p eh ~p h ~p", [Name, Height0, ElectionHeight]),
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
                blockchain_election:election_info(blockchain:ledger(Chain), Chain)
            catch _:_ ->
                    #{}
            end
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    ok = blockchain_event:add_handler(self()),
    case  blockchain_worker:blockchain() of
        undefined ->
            {ok, #state{}};
        Chain ->
            {ok, #state{chain = Chain}, 0}
    end.

%% in the call handlers, we wait for the dkg to return, and then once
%% it does, we communicate with the miner
handle_call({sign_genesis_block, GenesisBlock, _PrivateKey}, _From, State) ->
    {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
    Signature = SignFun(GenesisBlock),
    Address = libp2p_crypto:pubkey_to_bin(MyPubKey),
    {reply, {ok, Address, Signature}, State};
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
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("started initial hbbft group: ~p~n", [Group]),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    miner_hbbft_sidecar:set_group(Group),
    miner:start_chain(Group, Chain),

    #{ {1,0} := DKGGroup} = State#state.current_dkgs,
    {reply, ok, State#state{active_group = Group,
                            current_dkgs = #{},
                            cancel_dkgs = #{3 => DKGGroup},
                            chain = Chain}};
handle_call({election_done, _Artifact, Signatures, Members, PrivKey, Height, Delay}, _From,
            State = #state{chain = Chain,
                           started_groups = Groups}) ->
    lager:info("election done at ~p delay ~p", [Height, Delay]),
    {ok, N} = blockchain:config(?num_consensus_members, blockchain:ledger(Chain)),
    F = ((N - 1) div 3),

    Proof = term_to_binary(Signatures, [compressed]),

    %% first we need to add ourselves to the chain for the existing
    %% group to validate
    %% TODO we should also add this to the buffer of the local chain
    {ok, ElectionHeight} = blockchain_ledger_v1:election_height(blockchain:ledger(Chain)),
    case ElectionHeight < Height of
        true ->
            ok = blockchain_worker:submit_txn(
                   blockchain_txn_consensus_group_v1:new(Members, Proof, Height, Delay),
                   fun(Res) ->
                           case Res of
                               ok ->
                                   lager:info("Election successful, Height: ~p, Members: ~p, Proof: ~p, Delay: ~p!",
                                              [Height, Members, Proof, Delay]);
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
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),

    %% not sure what the correct error behavior here is?
    started = wait_for_group(Group),
    lager:info("checking that the hbbft group has successfully started"),
    true = libp2p_group_relcast:handle_command(Group, have_key),

    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
    {reply, ok, State#state{started_groups = Groups#{{Height, Delay} => Group}}};
handle_call({rescue_done, _Artifact, _Signatures, Members, PrivKey, _Height, _Delay}, _From,
            State = #state{chain = Chain}) ->
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:election_height(Ledger),
    lager:info("rescue election done at ~p", [Height]),

    {ok, N} = blockchain:config(num_consensus_members, Ledger),
    F = ((N - 1) div 3),
    {ok, BatchSize} = blockchain:config(batch_size, Ledger),
    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), Members),

    {ok, Block} = blockchain:head_block(Chain),
    Round = blockchain_block:hbbft_round(Block),

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
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
    %% adjust the height upwards, the rescue will be from one block
    %% above the present one.
    ok = miner:install_consensus(Group),
    %% here the dkg has already been moved into the cancel state.
    stop_group(State#state.active_group),
    miner_hbbft_sidecar:set_group(Group),
    libp2p_group_relcast:handle_input(Group, {next_round, Round + 1, [], false}),

    {reply, ok, State#state{active_group = Group}};
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
            {reply, ok, NonDKGState}
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
    Ledger = blockchain:ledger(Chain),
    {ok, ConsensusGroup} = blockchain_ledger_v1:consensus_members(Ledger),
    MyAddr = blockchain_swarm:pubkey_bin(),
    {reply, lists:member(MyAddr, ConsensusGroup), State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            #state{current_dkgs = DKGs,
                   cancel_dkgs = CancelDKGs} = State)
  when State#state.chain /= undefined ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),
    Now = erlang:system_time(seconds),
    case blockchain:get_block(Hash, State#state.chain) of
        {ok, Block} ->
            case Sync andalso (Now - blockchain_block:time(Block) > 3600) of
                %% not sync, or recent sync
                false ->
                    BlockHeight = blockchain_block:height(Block),
                    lager:info("processing block height ~p", [BlockHeight]),
                    State1 = case maps:find(BlockHeight, CancelDKGs) of
                                 error ->
                                     State;
                                 {ok, Group} ->
                                     lager:info("canceling DKG ~p at height ~p", [Group, BlockHeight]),
                                     catch libp2p_group_relcast:handle_command(Group, {stop, 120000}),
                                     State#state{cancel_dkgs = maps:remove(BlockHeight, CancelDKGs)}
                             end,
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
                        case ElectionRunning andalso (not maps:is_key({Height, Delay}, DKGs)) of
                            true ->
                                %% start the election running here
                                lager:info("starting new election at ~p+~p", [Height, Delay]),
                                initiate_election(Hash, Height,
                                                  State1#state{delay = Delay,
                                                               initial_height = Height});
                            false ->
                                State1#state{delay = Delay,
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
                                        stop_group(State2#state.active_group),
                                        miner_hbbft_sidecar:set_group(undefined),
                                        State2#state{active_group = undefined};
                                    {ok, out} ->
                                        stop_group(State2#state.active_group),
                                        miner_hbbft_sidecar:set_group(undefined),
                                        State2#state{current_dkgs = maps:remove(EID, State2#state.current_dkgs),
                                                     active_group = undefined};
                                    {ok, ElectionGroup} ->
                                        HBBFTGroup =
                                            case maps:find(EID, State#state.started_groups) of
                                                {ok, HGrp} ->
                                                    HGrp;
                                                error ->
                                                    lager:info("starting hbbft ~p+~p at block height ~p",
                                                               [ElectionHeight, ElectionDelay, BlockHeight]),
                                                    {ok, HGrp} = start_hbbft(ElectionGroup, ElectionHeight,
                                                                             ElectionDelay, State2#state.chain),
                                                    HGrp
                                            end,
                                        Round = blockchain_block:hbbft_round(Block),
                                        activate_hbbft(HBBFTGroup, State#state.active_group, Round),
                                        State2#state{current_dkgs = maps:remove(EID, cleanup_groups(EID, State2#state.current_dkgs)),
                                                     cancel_dkgs = CancelDKGs#{BlockHeight+2 => ElectionGroup},
                                                     started_groups = cleanup_groups(EID, State#state.started_groups),
                                                     active_group = HBBFTGroup}
                                end,
                            {noreply, State3#state{delay = 0}};
                        false when ElectionRunning ->
                            NextRestart = Height + RestartInterval + Delay,
                            case BlockHeight of
                                NewHeight when NewHeight >= NextRestart  ->
                                    lager:info("restart! h ~p next ~p", [NewHeight, NextRestart]),
                                    %% restart the dkg
                                    State3 = restart_election(State2, Hash, Height),
                                    {LastGroup, DKGs1} = maps:take({Height, Delay}, State3#state.current_dkgs),
                                    {noreply, State3#state{current_dkgs = DKGs1,
                                                           cancel_dkgs = CancelDKGs#{Height+Delay+2 =>
                                                                                         LastGroup}}};
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
    {noreply, State#state{chain = NC}};
%% we had a chain to start with, so check restore state
handle_info(timeout, State) ->
    {ok, HeadBlock} = blockchain:head_block(State#state.chain),
    StartHeight = blockchain_block:height(HeadBlock),

    lager:info("try cold start consensus group at ~p", [StartHeight]),

    Chain = blockchain_worker:blockchain(),
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
            case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
                true ->
                    #{election_height := ElectionHeight,
                      election_delay := ElectionDelay} =
                        blockchain_election:election_info(Ledger, Chain),
                    lager:info("in group, trying to restore"),
                    {ok, Block} = blockchain:head_block(Chain),
                    BlockHeight = blockchain_block:height(Block),
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
                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                         Name,
                                                         libp2p_group_relcast, GroupArg),
                    Round = blockchain_block:hbbft_round(HeadBlock),
                    case wait_for_group(Group) of
                        started ->
                            activate_hbbft(Group, undefined, Round),
                            %% we already completed our election
                            {noreply, State#state{active_group = Group}};
                        {error, cannot_start} ->
                            %% TODO: rip this out in a few versions
                            FallbackName = consensus_group_name(ElectionHeight, fallback, ConsensusAddrs),
                            {ok, FallbackGroup} =
                                libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                       FallbackName,
                                                       libp2p_group_relcast, GroupArg),
                            case wait_for_group(FallbackGroup) of
                                started ->
                                    lager:info("restored fallback group"),
                                    activate_hbbft(FallbackGroup, undefined, Round),
                                    {noreply, State#state{active_group = FallbackGroup}};
                                {error, cannot_start} ->
                                    lager:info("didn't restore consensus group, missing"),
                                    ok = libp2p_swarm:remove_group(blockchain_swarm:swarm(), Name),
                                    State1 = case BlockHeight < (ElectionHeight+ElectionDelay+10) of
                                                 true ->
                                                     restore_dkg(ElectionHeight, ElectionDelay, BlockHeight, Round, State);
                                                 _ ->
                                                     State
                                             end,
                                    {noreply, State1}
                            end;
                        {error, Reason} ->
                            lager:info("didn't restore consensus group: ~p", [Reason]),
                            ok = libp2p_swarm:remove_group(blockchain_swarm:swarm(), Name),
                            {noreply, State}
                    end;
                false ->
                    %% still need to check if we're in the election
                    %% group here
                    {_, EpochStart} = blockchain_block_v1:election_info(HeadBlock),
                    case next_election(EpochStart, ElectionInterval) of
                        ElectionHeight when ElectionHeight =< StartHeight ->
                            Diff = StartHeight - ElectionHeight,
                            Delay = max(0, (Diff div RestartInterval) * RestartInterval),
                            State1 = State#state{initial_height = ElectionHeight,
                                                 delay = Delay},

                            Election = ElectionHeight + Delay,
                            {ok, ElectionBlock} = blockchain:get_block(Election, Chain),
                            Hash = blockchain_block:hash_block(ElectionBlock),
                            State2 = initiate_election(Hash, StartHeight, State1),
                            lager:info("not restoring consensus group: not a member"),
                            {noreply, State2};
                        _ ->
                            {noreply, State}
                    end
            end
    end;
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, #state{active_group = Active,
                          started_groups = Started,
                          current_dkgs = Current,
                          cancel_dkgs = Cancel}) ->
    stop_group(Active),
    maps:map(fun(_, G) -> stop_group(G) end, Started),
    maps:map(fun(_, G) -> stop_group(G) end, Current),
    maps:map(fun(_, G) -> stop_group(G) end, Cancel),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

initiate_election(Hash, Height, #state{delay = Delay} = State) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    lager:info("hash ~p height ~p delay ~p", [Hash, Height, Delay]),
    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    Artifact = term_to_binary(ConsensusAddrs),

    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                         election_done, N, Curve, true, State#state{initial_height = Height}),

    State1.

restart_election(#state{delay = Delay,
                        chain=Chain} = State, Hash, Height) ->

    Ledger = blockchain:ledger(Chain),
    lager:warning("restarting election at ~p delay ~p", [Height, Delay]),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    case length(ConsensusAddrs) == N of
        true ->
            Artifact = term_to_binary(ConsensusAddrs),
            {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                                 election_done, N, Curve, true, State#state{delay = Delay}),
            State1;
        false ->
            lager:warning("issue generating new group.  skipping restart"),
            State
    end.

rescue_dkg(Members, Artifact, State) ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, Curve} = blockchain:config(dkg_curve, Ledger),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),

    {_, State1} = do_dkg(Members, Artifact, {?MODULE, sign_genesis_block},
                         rescue_done, length(Members), Curve, true,
                         State#state{initial_height = Height,
                                     delay = 0}),
    State1.

restore_dkg(Height, Delay, CurrHeight, Round, State) ->
    Ledger = blockchain:ledger(State#state.chain),
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    {ok, BatchSize} = blockchain:config(?batch_size, Ledger),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),
    Artifact = term_to_binary(ConsensusAddrs),
    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                         election_done, length(ConsensusAddrs), Curve, false,
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
                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                         Name,
                                                         libp2p_group_relcast, GroupArg),

                    %% not sure what the correct error behavior here is?
                    lager:info("checking that the hbbft group has successfully started"),
                    started = wait_for_group(Group),
                    true = libp2p_group_relcast:handle_command(Group, have_key),
                    lager:info("restore start group ~p ~p in pos ~p", [Name, Group, Pos]),
                    activate_hbbft(Group, undefined, Round),
                    #state{cancel_dkgs = CancelDKGs,
                           current_dkgs = DKGs} = State1,
                    {DKGGroup, DKGs1} = maps:take({Height, Delay}, DKGs),
                    State1#state{active_group = Group,
                                 cancel_dkgs = CancelDKGs#{CurrHeight+10 =>
                                                               DKGGroup},
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
    do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
           genesis_block_done, N, Curve, true, State).

do_dkg(Addrs, Artifact, Sign, Done, N, Curve, Create,
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
    lager:info("MyAddress: ~p", [MyAddress]),
    case lists:member(MyAddress, ConsensusAddrs) of
        true ->
            lager:info("Preparing to run DKG #~p at height ~p ", [Delay, Height]),
            Pos = miner_util:index_of(MyAddress, ConsensusAddrs),

            Swarm = blockchain_swarm:swarm(),

            %% To ensure the DKG can actually complete, attempt to fastforward all the
            %% DKG peers so they all know they're in the newly proposed consensus group
            lists:foreach(fun(Member) ->
                                  spawn(fun() ->
                                                libp2p_swarm:dial_framed_stream(Swarm, libp2p_crypto:pubkey_bin_to_p2p(Member), ?FASTFORWARD_PROTOCOL, blockchain_fastforward_handler, [Chain])
                                        end)
                          end, ConsensusAddrs -- [MyAddress]),

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
                                            Curve,
                                            Artifact,
                                            Sign,
                                            {?MODULE, Done}, list_to_binary(DKGGroupName),
                                            Height,
                                            Delay],
                       [{create, Create}]],

            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                    DKGGroupName,
                                                    libp2p_group_relcast,
                                                    GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            lager:info("height ~p Address: ~p, ConsensusWorker pos: ~p, Group name ~p",
                       [Height, MyAddress, Pos, DKGGroupName]),
            {true, State#state{current_dkgs = DKGs#{{Height, Delay} => DKGGroup}}};
        false ->
            lager:info("not in DKG this round at height ~p ~p", [Height, Delay]),
            {false, State#state{current_dkgs = DKGs#{{Height, Delay} => out}}}
    end.

start_hbbft(DKG, Height, Delay, Chain) ->
    Ledger = blockchain:ledger(Chain),
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
            {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                 Name,
                                                 libp2p_group_relcast, GroupArg),

            %% not sure what the correct error behavior here is?
            lager:info("checking that the hbbft group has successfully started"),
            started = wait_for_group(Group),
            true = libp2p_group_relcast:handle_command(Group, have_key),
            ok = libp2p_group_relcast:handle_command(DKG, mark_done),

            lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, Pos]),
            ok = miner:install_consensus(Group),
            {ok, Group};
        {error, not_done} ->
            {error, not_done}
    end.

activate_hbbft(Group, PrevGroup, Round) ->
    Buf = get_buf(PrevGroup),
    set_buf(Group, Buf),
    miner_hbbft_sidecar:set_group(Group),
    libp2p_group_relcast:handle_input(Group, {next_round, Round + 1, [], false}),
    miner:install_consensus(Group).

consensus_group_name(Height, fallback, Members) ->
    lists:flatten(io_lib:format("consensus_~b_~b", [Height, erlang:phash2(Members)]));
consensus_group_name(Height, Delay, Members) ->
    lists:flatten(io_lib:format("consensus_~b_~b_~b", [Height, Delay, erlang:phash2(Members)])).

animalize(L) ->
    lists:map(fun(X0) ->
                      X = libp2p_crypto:bin_to_b58(X0),
                      {ok, N} = erl_angry_purple_tiger:animal_name(X),
                      N
              end,
              L).

%% TODO: redo this using proper time accounting
wait_for_group(Group) ->
    wait_for_group(Group, 5).

wait_for_group(_Group, 0) ->
    {error, could_not_check};
wait_for_group(Group, Retries) ->
    case libp2p_group_relcast:status(Group) of
        started ->
            started;
        cannot_start ->
            {error, cannot_start};
        not_started ->
            timer:sleep(500),
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
stop_group(Pid) ->
    spawn(fun() ->
                  catch libp2p_group_relcast:handle_command(Pid, {stop, 0})
          end),
    ok.

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

cleanup_groups({Start, _Delay} = EID, Groups) ->
    lager:info("cleaning up old groups on election of ~p", [EID]),
    maps:fold(
      %% this is the new active group. remove but don't stop
      fun(K, _V, G) when K == EID ->
              lager:info("ignoring new group"),
              G;
         %% group from same or older start height, stop and remove
         ({S, _D} = E, V, G) when S =< Start ->
              lager:info("stopping group ~p ~p", [E, V]),
              stop_group(V),
              G;
         (K, V, G) ->
              G#{K => V}
      end,
      #{},
      Groups).
