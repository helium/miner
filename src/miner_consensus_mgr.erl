-module(miner_consensus_mgr).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").

%% API
-export([
         start_link/1,

         initial_dkg/2,
         maybe_start_election/3,
         start_election/2,
         maybe_start_consensus_group/1,

         %% internal
         genesis_block_done/4,
         election_done/4,
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
         hash :: undefined | binary(),
         consensus_pos :: undefined | pos_integer(),
         initial_height = 0 :: non_neg_integer(),
         initial_hash :: binary(),
         n :: undefined | pos_integer(),
         curve :: atom(),
         batch_size :: integer(),
         tries = 0 :: integer(),
         timer_ref :: undefined | reference()
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



initial_dkg(GenesisTransactions, Addrs) ->
    gen_server:call(?MODULE, {initial_dkg, GenesisTransactions, Addrs}, infinity).

maybe_start_election(_Hash, Height, NextElection) when Height < NextElection ->
    lager:info("not starting election ~p", [{_Hash, Height, NextElection}]),
    ok;
maybe_start_election(Hash, _, NextElection) ->
    start_election(Hash, NextElection).

start_election(Hash, Height) ->
    gen_server:call(?MODULE, {start_election, Hash, Height}, infinity).

maybe_start_consensus_group(StartHeight) ->
    gen_server:call(?MODULE, {maybe_start_consensus_group, StartHeight}, infinity).

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
    gen_server:call(?MODULE, {election_done, Artifact, Signatures, Members, PrivKey}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% two versions, one for an election, one for the genesis block

init(Args) ->
    %% election version

    BatchSize = proplists:get_value(batch_size, Args),
    Curve = proplists:get_value(curve, Args),

    {ok, #state{batch_size = BatchSize,
                curve = Curve}}.

%% in the call handlers, we wait for the dkg to return, and then once
%% it does, we communicate with the miner
handle_call({sign_genesis_block, GenesisBlock, _PrivateKey}, _From, State) ->
    {ok, MyPubKey, SignFun} = blockchain_swarm:keys(),
    Signature = SignFun(GenesisBlock),
    Address = libp2p_crypto:pubkey_to_bin(MyPubKey),
    {reply, {ok, Address, Signature}, State};
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, Members, PrivKey}, _From,
            #state{batch_size = BatchSize} = State) ->
    GenesisBlock = blockchain_block:deserialize(BinaryGenesisBlock),
    SignedGenesisBlock = blockchain_block:set_signatures(GenesisBlock, Signatures),
    lager:notice("Got a signed genesis block: ~p", [SignedGenesisBlock]),

    case State#state.dkg_await of
        undefined -> ok;
        From -> gen_server:reply(From, ok)
    end,

    ok = blockchain_worker:integrate_genesis_block(SignedGenesisBlock),
    N = blockchain_worker:num_consensus_members(),
    F = ((N - 1) div 3),
    Chain = blockchain_worker:blockchain(),
    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1,
                                      []]],
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus_1",
                                         libp2p_group_relcast, GroupArg),
    lager:info("started initial hbbft group: ~p~n", [Group]),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    miner:start_chain(Group, Chain),
    {reply, ok, State#state{current_dkg = undefined}};
handle_call({election_done, _Artifact, Signatures, Members, PrivKey}, _From,
            State = #state{batch_size = BatchSize,
                           initial_height = Height,
                           tries = Tries}) ->
    lager:info("election done at ~p tries ~p", [Height, Tries]),
    erlang:cancel_timer(State#state.timer_ref),

    N = blockchain_worker:num_consensus_members(),
    F = ((N - 1) div 3),
    Chain = blockchain_worker:blockchain(),

    Proof = term_to_binary(Signatures, [compressed]),

    %% first we need to add ourselves to the chain for the existing
    %% group to validate
    %% TODO we should also add this to the buffer of the local chain
    blockchain_txn_manager:submit(blockchain_txn_consensus_group_v1:new(Members, Proof, Height, Tries), Members),
    blockchain_txn_manager ! timeout, % awful

    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      1, % gets set later
                                      []]], % gets filled later
    %% while this won't reflect the actual height, it has to be deterministic
    Name = "consensus_" ++ integer_to_list(max(0, Height)),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, State#state.consensus_pos]),
    ok = miner:handoff_consensus(Group),
    {reply, ok, State#state{current_dkg = undefined,
                            tries = 1,
                            initial_hash = undefined,
                            timer_ref = undefined}};
handle_call({maybe_start_consensus_group, StartHeight}, _From,
            State = #state{batch_size = BatchSize}) ->
    lager:info("try cold start consensus group at ~p", [StartHeight]),

    N = blockchain_worker:num_consensus_members(),
    F = ((N - 1) div 3),
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:consensus_members(Ledger) of
        {error, _} ->
            lager:info("not restoring consensus group: no chain"),
            {reply, undefined, State};
        {ok, ConsensusAddrs} ->
            case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
                true ->
                    lager:info("restoring consensus group"),
                    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
                    GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
                                                      Pos,
                                                      N,
                                                      F,
                                                      BatchSize,
                                                      undefined,
                                                      Chain]],
                    %% while this won't reflect the actual height, it has to be deterministic
                    Name = "consensus_" ++ integer_to_list(StartHeight),
                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                         Name,
                                                         libp2p_group_relcast, GroupArg),
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
                false ->
                    lager:info("not restoring consensus group: not a member"),
                    {reply, undefined, State}
            end
    end;
handle_call(dkg_group, _From, #state{current_dkg = Group} = State) ->
    {reply, Group, State};
handle_call({initial_dkg, GenesisTransactions, Addrs}, From, State0) ->
    State = State0#state{initial_height = 1,
                         tries = 0},
    case do_initial_dkg(GenesisTransactions, Addrs, State) of
        {true, DKGState} ->
            lager:info("Waiting for DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {noreply, DKGState#state{dkg_await=From}};
        {false, NonDKGState} ->
            lager:info("Not running DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {reply, ok, NonDKGState}
    end;
handle_call({start_election, _Hash, Height}, _From, State)
  when Height =< State#state.initial_height ->
    lager:info("election already ran at ~p bc initial ~p", [Height, State#state.initial_height]),
    {reply, already_ran, State};
handle_call({start_election, Hash, Height}, _From,
            #state{current_dkg = undefined} = State0) ->
    lager:info("election started at ~p", [Height]),
    State = State0#state{initial_height = Height,
                         tries = 1},
    State1 = initiate_election(Hash, Height, State),
    {reply, State1#state.current_dkg /= undefined, State1};
handle_call({start_election, _Hash, _Height}, _From, State) ->
    lager:info("election started at ~p, already running", [_Height]),
    {reply, already_running, State};
handle_call(consensus_pos, _From, State) ->
    {reply, State#state.consensus_pos, State};
%% TODO: currently broken
handle_call(in_consensus, _From, #state{consensus_pos = Pos} = State) ->
    {reply, is_integer(Pos), State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

%% for the genesis block, since there will be an operator, we don't
%% bother to set up a timeout for the dkg.
handle_info(dkg_timeout, #state{current_dkg = OldDKG} = State) ->
    %% kill the running dkg
    catch libp2p_group_relcast:handle_command(OldDKG, {stop, 0}),
    %% restart the dkg
    State1 = restart_election(State),
    {noreply, State1};
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

initiate_election(Hash, Height, State) ->
    Chain = blockchain_worker:blockchain(),
    N = blockchain_worker:num_consensus_members(),

    Ledger = blockchain:ledger(Chain),
    OrderedGateways = blockchain_election:new_group(Ledger, Hash, N, 1),
    ConsensusAddrs = lists:sublist(OrderedGateways, 1, N),
    Artifact = term_to_binary(ConsensusAddrs),

    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                         election_done, State#state{initial_height = Height,
                                                    n = N,
                                                    initial_hash = Hash}),

    %% TODO: the timeout here should be generously longer than even the
    %% longest dkg, as the potential for chain-forking dkg timeouts is
    %% IMMENSE. I suspect that even the timeout prior to the restart
    %% should be threaded through the existing consensus group for safety.

    Timeout = get_dkg_timeout(),
    Ref = erlang:send_after(Timeout, self(), dkg_timeout),
    State1#state{timer_ref = Ref}.

restart_election(#state{n = N,
                        initial_hash = Hash,
                        tries = Try0} = State) ->
    lager:warning("RESTARTING ELECTION, HERE BE LASERSHARKS"),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    Try = Try0 + 1,

    OrderedGateways = blockchain_election:new_group(Ledger, Hash, N, Try),
    ConsensusAddrs = lists:sublist(OrderedGateways, (N * (Try - 1)) + 1, N),
    case length(ConsensusAddrs) == N of
        true ->
            ok;
        false ->
            error({too_short, (N * (Try - 1)) + 1, ConsensusAddrs})
    end,
    Artifact = term_to_binary(ConsensusAddrs),

    {_, State1} = do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block},
                         election_done, State#state{tries = Try}),
    Timeout = get_dkg_timeout(),
    Ref = erlang:send_after(Timeout, self(), dkg_timeout),
    State1#state{timer_ref = Ref}.

do_initial_dkg(GenesisTransactions, Addrs, State) ->
    lager:info("do initial"),
    SortedAddrs = lists:sort(Addrs),
    N = blockchain_worker:num_consensus_members(),

    ConsensusAddrs = lists:sublist(SortedAddrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
    %% in the consensus group, run the dkg
    GenesisBlockTransactions = GenesisTransactions ++
        [blockchain_txn_consensus_group_v1:new(ConsensusAddrs, <<>>, 1, 0)],
    Artifact = blockchain_block:serialize(blockchain_block:new_genesis_block(GenesisBlockTransactions)),
    do_dkg(ConsensusAddrs, Artifact, {?MODULE, sign_genesis_block}, genesis_block_done, State#state{n = N}).

do_dkg(Addrs, Artifact, Sign, Done,
       State=#state{initial_height = Height,
                    n = N,
                    tries = Tries,
                    curve = Curve}) ->

    lager:info("N: ~p", [N]),
    F = ((N-1) div 3),
    lager:info("F: ~p", [F]),
    ConsensusAddrs = lists:sublist(Addrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
    MyAddress = blockchain_swarm:pubkey_bin(),
    lager:info("MyAddress: ~p", [MyAddress]),
    case lists:member(MyAddress, ConsensusAddrs) of
        true ->
            lager:info("Preparing to run DKG #~p at height ~p ", [Tries, Height]),
            miner_ebus:send_signal("ConsensusElect", "Elected"),
            Pos = miner_util:index_of(MyAddress, ConsensusAddrs),

            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            Pos,
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Curve,
                                            Artifact,
                                            Sign,
                                            {?MODULE, Done}]],
            %% make a simple hash of the consensus members
            DKGHash = base58:binary_to_base58(crypto:hash(sha, term_to_binary(ConsensusAddrs))),
            DKGCount = "-" ++ integer_to_list(Height),
            DKGTries = "-" ++ integer_to_list(Tries),
            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                    "dkg-"++DKGHash++DKGCount++DKGTries,
                                                    libp2p_group_relcast,
                                                    GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            lager:info("height ~p Address: ~p, ConsensusWorker pos: ~p",
                       [Height, MyAddress, Pos]),
            {true, State#state{consensus_pos = Pos,
                               current_dkg = DKGGroup}};
        false ->
            miner_ebus:send_signal("ConsensusElect", "Defeated"),
            lager:info("not in DKG this round at height ~p", [Height]),
            {false, State#state{consensus_pos = undefined,
                                current_dkg = undefined}}
    end.

get_dkg_timeout() ->
    application:get_env(miner, dkg_timeout, timer:seconds(15)).
