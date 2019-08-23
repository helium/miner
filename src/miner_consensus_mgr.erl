-module(miner_consensus_mgr).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

%% API
-export([
         start_link/1,

         initial_dkg/4,
         maybe_start_election/3,
         start_election/3,
         maybe_start_consensus_group/1,
         cancel_dkg/0,

         %% internal
         genesis_block_done/4,
         election_done/4,
         rescue_done/4,
         sign_genesis_block/2,

         %% info
         consensus_pos/0,
         in_consensus/0,
         dkg_status/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         current_dkg :: undefined | pid(),
         dkg_await :: undefined | {reference(), term()},
         consensus_pos :: undefined | pos_integer(),
         initial_height = 1 :: non_neg_integer(),
         delay = 0 :: integer(),
         chain :: undefined | blockchain:blockchain(),
         election_running = false :: boolean()
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

maybe_start_election(_Hash, Height, NextElection) when Height =/= NextElection ->
    lager:debug("not starting election ~p", [{_Hash, Height, NextElection}]),
    ok;
maybe_start_election(Hash, _, NextElection) ->
    start_election(Hash, NextElection, NextElection).

start_election(Hash, CurrentHeight, StartHeight) ->
    gen_server:call(?MODULE, {start_election, Hash, CurrentHeight, StartHeight}, infinity).

maybe_start_consensus_group(StartHeight) ->
    gen_server:call(?MODULE, {maybe_start_consensus_group, StartHeight}, infinity).

cancel_dkg() ->
    gen_server:call(?MODULE, cancel_dkg, infinity).

-spec sign_genesis_block(GenesisBlock :: binary(), PrivKey :: tpke_privkey:privkey()) ->
                                {ok, libp2p_crypto:pubkey_bin(), binary()}.
sign_genesis_block(GenesisBlock, PrivKey) ->
    gen_server:call(?MODULE, {sign_genesis_block, GenesisBlock, PrivKey}).

-spec genesis_block_done(GenesisBLock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         Members :: [libp2p_crypto:address()],
                         PrivKey :: tpke_privkey:privkey()) -> ok.
genesis_block_done(GenesisBlock, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures, Members, PrivKey}, infinity).

-spec election_done(binary(), [{libp2p_crypto:pubkey_bin(), binary()}],
                    [libp2p_crypto:address()], tpke_privkey:privkey()) -> ok.
election_done(Artifact, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {election_done, Artifact, Signatures, Members, PrivKey}, infinity).

rescue_done(Artifact, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {rescue_done, Artifact, Signatures, Members, PrivKey}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    ok = blockchain_event:add_handler(self()),
    case  blockchain_worker:blockchain() of
        undefined ->
            {ok, #state{}};
        Chain ->
            {ok, #state{chain = Chain}}
    end.

%% in the call handlers, we wait for the dkg to return, and then once
%% it does, we communicate with the miner
handle_call({sign_genesis_block, GenesisBlock, _PrivateKey}, _From, State) ->
    {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
    Signature = SignFun(GenesisBlock),
    Address = libp2p_crypto:pubkey_to_bin(MyPubKey),
    {reply, {ok, Address, Signature}, State};
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, Members, PrivKey}, _From,
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

    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1,
                                      []],
                [{create, true}]],
    Name = consensus_group_name(1, Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("started initial hbbft group: ~p~n", [Group]),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    miner:start_chain(Group, Chain),
    {reply, ok, State#state{current_dkg = undefined,
                            chain = Chain}};
handle_call({election_done, _Artifact, Signatures, Members, PrivKey}, _From,
            State = #state{initial_height = Height,
                           chain = Chain,
                           delay = Delay}) ->
    lager:info("election done at ~p delay ~p", [Height, Delay]),

    {ok, N} = blockchain:config(?num_consensus_members, blockchain:ledger(Chain)),
    F = ((N - 1) div 3),

    Proof = term_to_binary(Signatures, [compressed]),

    %% first we need to add ourselves to the chain for the existing
    %% group to validate
    %% TODO we should also add this to the buffer of the local chain
    ok = blockchain_worker:submit_txn(blockchain_txn_consensus_group_v1:new(Members, Proof, Height, Delay),
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
                                     ),
    {ok, BatchSize} = blockchain:config(?batch_size, blockchain:ledger(Chain)),

    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1, % gets set later
                                      []], % gets filled later
                [{create, true}]],
    %% while this won't reflect the actual height, it has to be deterministic
    Name = consensus_group_name(max(0, Height), Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),

    %% not sure what the correct error behavior here is?
    lager:info("checking that the hbbft group has successfully started"),
    true = libp2p_group_relcast:handle_command(Group, have_key),

    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, State#state.consensus_pos]),
    ok = miner:handoff_consensus(Group, Height + Delay),
    {reply, ok, State#state{current_dkg = undefined}};
handle_call({rescue_done, _Artifact, _Signatures, Members, PrivKey}, _From,
            State = #state{chain = Chain}) ->
    {ok, Height} = blockchain_ledger_v1:election_height(blockchain:ledger(Chain)),
    lager:info("rescue election done at ~p", [Height]),

    {ok, N} = blockchain:config(num_consensus_members, blockchain:ledger(Chain)),
    F = ((N - 1) div 3),
    {ok, BatchSize} = blockchain:config(batch_size, blockchain:ledger(Chain)),

    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1, % gets set later
                                      []],
                [{create, true}]], % gets filled later
    %% while this won't reflect the actual height, it has to be deterministic
    Name = consensus_group_name(max(0, Height), Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, State#state.consensus_pos]),
    %% adjust the height upwards, the rescue will be from one block
    %% above the present one.
    ok = miner:handoff_consensus(Group, Height, true),
    {reply, ok, State#state{current_dkg = undefined, delay = 0, election_running = false}};
handle_call({maybe_start_consensus_group, StartHeight}, _From,
            State) ->
    lager:info("try cold start consensus group at ~p", [StartHeight]),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    F = ((N - 1) div 3),
    case blockchain_ledger_v1:consensus_members(Ledger) of
        {error, _} ->
            lager:info("not restoring consensus group: no chain"),
            {reply, undefined, State};
        {ok, ConsensusAddrs} ->
            case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
                true ->
                    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
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
                    Name = consensus_group_name(StartHeight, ConsensusAddrs),
                    lager:info("restoring consensus group ~p", [Name]),
                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                         Name,
                                                         libp2p_group_relcast, GroupArg),

                    case wait_for_group(Group) of
                        started ->
                            {ok, HeadBlock} = blockchain:head_block(Chain),
                            Round = blockchain_block:hbbft_round(HeadBlock),
                            libp2p_group_relcast:handle_input(
                              Group, {next_round, Round + 1, [], false}),
                            %% this isn't super safe?  must make sure that a prior group wasn't running
                            Height =
                                case StartHeight >= State#state.initial_height of
                                    true ->
                                        StartHeight;
                                    _ ->
                                        State#state.initial_height
                                end,
                            {reply, Group, State#state{consensus_pos = Pos,
                                                       initial_height = Height}};
                        {error, cannot_start} ->
                            lager:info("didn't restore consensus group, missing"),
                            ok = libp2p_swarm:remove_group(blockchain_swarm:swarm(), Name),
                            {reply, cannot_start, State};
                        {error, Reason} ->
                            lager:info("didn't restore consensus group: ~p", [Reason]),
                            ok = libp2p_swarm:remove_group(blockchain_swarm:swarm(), Name),
                            {reply, undefined, State}
                    end;
                false ->
                    lager:info("not restoring consensus group: not a member"),
                    {reply, undefined, State}
            end
    end;
handle_call(dkg_group, _From, #state{current_dkg = Group} = State) ->
    {reply, Group, State};
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
handle_call({start_election, _Hash, _Current, Height}, _From, State)
  when Height =< State#state.initial_height ->
    lager:info("election already ran at ~p bc initial ~p", [Height, State#state.initial_height]),
    {reply, already_ran, State};
handle_call({start_election, Hash0, CurrentHeight, StartHeight}, _From,
            #state{current_dkg = undefined, chain = Chain} = State0) ->
    lager:info("election started at ~p curr ~p", [StartHeight, CurrentHeight]),
    Diff = CurrentHeight - StartHeight,
    Ledger = blockchain:ledger(Chain),
    {ok, Interval} = blockchain:config(?election_restart_interval, Ledger),

    Delay = (Diff div Interval) * Interval,
    State = State0#state{initial_height = StartHeight,
                         delay = Delay},
    %% this is a crappy workaround for not wanting to duplicate the
    %% delay calculation logic in the miner as well. in other cases
    %% the hash is always correct, but we can do the work more easily
    %% here in the restart case. this will go away when the restart
    %% logic is refactored into this module.
    Hash =
        case Hash0 of
            ignored ->
                Election = StartHeight + Delay,
                {ok, ElectionBlock} = blockchain:get_block(Election, Chain),
                blockchain_block:hash_block(ElectionBlock);
            _ -> Hash0
        end,
    State1 = initiate_election(Hash, StartHeight, State),
    {reply, State1#state.current_dkg /= undefined, State1};
handle_call({start_election, _Hash, _Current, _Height}, _From, State) ->
    lager:info("election started at ~p, already running", [_Height]),
    {reply, already_running, State};
handle_call(consensus_pos, _From, State) ->
    {reply, State#state.consensus_pos, State};
handle_call(in_consensus, _From, #state{chain=undefined, consensus_pos=Pos}=State) ->
    {reply, is_integer(Pos), State};
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
handle_call(cancel_dkg, _From, #state{election_running = false} = State) ->
    {reply, ok, State};
handle_call(cancel_dkg, _From, #state{current_dkg = DKG} = State) ->
    lager:info("cancelling DKG at ~p ~p", [State#state.initial_height,
                                           State#state.delay]),
    spawn(fun() ->
                  %% give the dkg some time to shut down so that
                  %% laggards get a chance to complete
                  Timeout = application:get_env(miner, dkg_stop_timeout, timer:minutes(5)),
                  catch libp2p_group_relcast:handle_command(DKG, {stop, Timeout})
          end),
    {reply, ok, State#state{current_dkg = undefined,
                            delay = 0,
                            election_running = false}};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, Hash, _Sync, _Ledger}},
            #state{current_dkg = OldDKG,
                   initial_height = Height,
                   delay = Delay} = State)
  when State#state.chain /= undefined ->

    Ledger = blockchain:ledger(State#state.chain),
    {ok, Interval} = blockchain:config(?election_restart_interval, Ledger),
    case blockchain:get_block(Hash, State#state.chain) of
        {ok, Block} ->
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
                            State1 = rescue_dkg(Members, term_to_binary(Members), State),
                            {noreply, State1};
                        false ->
                            lager:info("Not in rescue DKG: ~p", [Members]),
                            {noreply, State}
                    end;
                false when State#state.election_running and NewGroup /= false ->
                    %% if we got a new group
                    case OldDKG of
                        %% we're not in
                        undefined ->
                            {noreply, State#state{current_dkg = undefined,
                                                  delay = 0,
                                                  election_running = false}};
                        _ ->
                            start_hbbft(OldDKG, State),
                            catch libp2p_group_relcast:handle_command(OldDKG, {stop, 120000}),
                            {noreply, State#state{current_dkg = undefined,
                                                  delay = 0,
                                                  election_running = false}}
                    end;
                false when State#state.election_running ->
                    NextRestart = Height + Interval + Delay,
                    case blockchain_block:height(Block) of
                        NewHeight when NewHeight >= NextRestart  ->
                            lager:info("restart! h ~p next ~p", [NewHeight, NextRestart]),
                            catch libp2p_group_relcast:handle_command(OldDKG, {stop, 120000}),
                            %% restart the dkg
                            State1 = restart_election(State, Hash, Height),
                            {noreply, State1};
                        NewHeight ->
                            lager:info("restart? h ~p next ~p", [NewHeight, NextRestart]),
                            {noreply, State}
                    end;
                _Error ->
                    lager:warning("didn't get gossiped block: ~p", [_Error]),
                    {noreply, State}
            end
    end;
handle_info({blockchain_event, {add_block, _Hash, _Sync, _Ledger}}, State) ->
    case State#state.chain of
        undefined ->
            Chain = blockchain_worker:blockchain(),
            {noreply, State#state{chain = Chain}};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
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

    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    Artifact = term_to_binary(ConsensusAddrs),

    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                         election_done, N, Curve, State#state{initial_height = Height,
                                                              election_running = true}),

    State1.

restart_election(#state{delay = Delay0,
                        chain=Chain} = State, Hash, Height) ->

    Ledger = blockchain:ledger(Chain),
    {ok, Interval} = blockchain:config(?election_restart_interval, Ledger),

    Delay = Delay0 + Interval,
    lager:warning("restarting election at ~p delay ~p", [Height, Delay]),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    {ok, Curve} = blockchain:config(?dkg_curve, Ledger),

    ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
    case length(ConsensusAddrs) == N of
        true ->
            Artifact = term_to_binary(ConsensusAddrs),
            {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                                 election_done, N, Curve, State#state{delay = Delay}),
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
                         rescue_done, length(Members), Curve,
                         State#state{initial_height = Height,
                                     delay = 0,
                                     election_running = true}),
    State1.

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
           genesis_block_done, N, Curve, State).

do_dkg(Addrs, Artifact, Sign, Done, N, Curve,
       State=#state{initial_height = Height,
                    delay = Delay,
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
                                                libp2p_swarm:dial_framed_stream(Swarm, libp2p_crypto:pubkey_bin_to_p2p(Member), ?FASTFORWARD_PROTOCOL, blockchain_fastforward_handler, [length(Addrs), Chain])
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
                                            {?MODULE, Done}, list_to_binary(DKGGroupName)],
                       [{create, true}]],
            %% the opts are added in the third position of the list
            %% The below are for in_memory_mode
            %% [{db_opts, [{in_memory_mode, true}]},
            %%  {write_opts, [{disable_wal, true}]}]],
            %% The below are for in_memory, which seems the right option
            %% [{db_opts, [{in_memory, true}]}],

            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                    DKGGroupName,
                                                    libp2p_group_relcast,
                                                    GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            lager:info("height ~p Address: ~p, ConsensusWorker pos: ~p, Group name ~p",
                       [Height, MyAddress, Pos, DKGGroupName]),
            {true, State#state{consensus_pos = Pos,
                               current_dkg = DKGGroup}};
        false ->
            lager:info("not in DKG this round at height ~p ~p", [Height, Delay]),
            {false, State#state{consensus_pos = undefined,
                                current_dkg = undefined}}
    end.

start_hbbft(DKG, #state{initial_height = Height, delay = Delay} = State) ->
    {ok, BatchSize} = blockchain:config(?batch_size, blockchain:ledger(State#state.chain)),
    {info, PrivKey, Members, N, F} =  libp2p_group_relcast:handle_command(DKG, get_info),

    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      State#state.chain,
                                      1, % gets set later
                                      []], % gets filled later
                [{create, true}]],
    %% while this won't reflect the actual height, it has to be deterministic
    Name = consensus_group_name(max(0, Height), Members),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),

    %% not sure what the correct error behavior here is?
    lager:info("checking that the hbbft group has successfully started"),
    true = libp2p_group_relcast:handle_command(Group, have_key),

    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, State#state.consensus_pos]),
    ok = miner:handoff_consensus(Group, Height + Delay).

consensus_group_name(Height, Members) ->
    lists:flatten(io_lib:format("consensus_~b_~b", [Height, erlang:phash2(Members)])).

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
