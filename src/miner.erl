%%%-------------------------------------------------------------------

%% @doc miner
%% @end
%%%-------------------------------------------------------------------
-module(miner).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    pubkey_bin/0,
    add_gateway_txn/3,
    assert_loc_txn/4,
    initial_dkg/2,
    relcast_info/1,
    relcast_queue/1,
    consensus_pos/0,
    in_consensus/0,
    hbbft_status/0,
    hbbft_skip/0,
    create_block/3,
    signed_block/2,
    syncing_status/0,
    start_chain/2,
    handoff_consensus/3
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-record(state, {
    %% NOTE: a miner may or may not participate in consensus
    consensus_group :: undefined | pid(),
    consensus_start :: undefined | pos_integer(),
    dkg_group :: undefined | pid(),
    consensus_pos :: undefined | pos_integer(),
    batch_size = 500 :: pos_integer(),
    blockchain :: undefined | blockchain:blockchain(),
    %% but every miner keeps a timer reference?
    block_timer = make_ref() :: reference(),
    block_time = 15000 :: number(),
    %% TODO: this probably doesn't have to be here
    curve :: 'SS512',
    dkg_await :: undefined | {reference(), term()},
    currently_syncing = false :: boolean(),
    election_interval :: pos_integer(),
    current_dkg = undefined :: undefined | pos_integer(),
    current_height = -1 :: integer(),
    handoff_waiting = no :: no | {next_block, any()} | yes
}).

-define(H3_MINIMUM_RESOLUTION, 9).

-include_lib("blockchain/include/blockchain.hrl").

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec pubkey_bin() -> libp2p_crypto:pubkey_bin().
pubkey_bin() ->
    gen_server:call(?MODULE, pubkey_bin).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_gateway_txn(OwnerB58::string(),
                      Fee::pos_integer(),
                      Amount::non_neg_integer()) -> {ok, binary()}.
add_gateway_txn(OwnerB58, Fee, Amount) ->
    Owner = libp2p_crypto:b58_to_bin(OwnerB58),
    gen_server:call(?MODULE, {add_gateway_txn, Owner, Fee, Amount}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec assert_loc_txn(H3String::string(),
                     OwnerB58::string(),
                     Nonce::non_neg_integer(),
                     Fee::pos_integer()) -> {ok, binary()}.
assert_loc_txn(H3String, OwnerB58, Nonce, Fee) ->
    H3Index = h3:from_string(H3String),
    Owner = libp2p_crypto:b58_to_bin(OwnerB58),
    gen_server:call(?MODULE, {assert_loc_txn, H3Index, Owner, Nonce, Fee}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
initial_dkg(GenesisTransactions, Addrs) ->
    gen_server:call(?MODULE, {initial_dkg, GenesisTransactions, Addrs}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
relcast_info(Group) ->
    case gen_server:call(?MODULE, Group, 60000) of
        undefined -> #{};
        Pid ->
            libp2p_group_relcast:info(Pid)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
relcast_queue(Group) ->
    case gen_server:call(?MODULE, Group, 60000) of
        undefined -> #{};
        Pid ->
            try libp2p_group_relcast:queues(Pid) of
                {_ModState, Inbound, Outbound} ->
                    O = maps:map(
                        fun(_, V) ->
                            [erlang:binary_to_term(Value) || Value <- V]
                        end,
                        Outbound
                    ),
                    I = [{Index,binary_to_term(B)} || {Index, B} <- Inbound],
                    #{
                        inbound => I,
                        outbound => O
                    }
            catch What:Why ->
                      {error, {What, Why}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec consensus_pos() -> non_neg_integer().
consensus_pos() ->
    gen_server:call(?MODULE, consensus_pos).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec in_consensus() -> boolean().
in_consensus() ->
    gen_server:call(?MODULE, in_consensus).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_block(Stamps :: [{non_neg_integer(), {pos_integer(), binary()}},...],
                   Txns :: blockchain_txn:txns(),
                   HBBFTRound :: non_neg_integer())
                  -> {ok,
                      libp2p_crypto:pubkey_bin(),
                      binary(),
                      binary(),
                      blockchain_txn:txns()} |
                     {error, term()}.
create_block(Stamps, Txns, HBBFTRound) ->
    gen_server:call(?MODULE, {create_block, Stamps, Txns, HBBFTRound}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
hbbft_status() ->
    case gen_server:call(?MODULE, consensus_group, 60000) of
        undefined -> ok;
        Pid ->
            Ref = make_ref(),
            ok = libp2p_group_relcast:handle_input(Pid, {status, Ref, self()}),
            receive
                {Ref, Result} ->
                    Result
            after timer:seconds(60) ->
                      {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
hbbft_skip() ->
    case gen_server:call(?MODULE, consensus_group, 60000) of
        undefined -> ok;
        Pid ->
            Ref = make_ref(),
            ok = libp2p_group_relcast:handle_input(Pid, {skip, Ref, self()}),
            receive
                {Ref, Result} ->
                    Result
            after timer:seconds(60) ->
                      {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
dkg_status() ->
    case gen_server:call(?MODULE, dkg_group, 60000) of
        undefined -> ok;
        Pid ->
            Ref = make_ref(),
            ok = libp2p_group_relcast:handle_input(Pid, {status, Ref, self()}),
            receive
                {Ref, Result} ->
                    Result
            after timer:seconds(60) ->
                      {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec signed_block([binary()], binary()) -> ok.
signed_block(Signatures, BinBlock) ->
    %% this should be a call so we don't lose state
    gen_server:call(?MODULE, {signed_block, Signatures, BinBlock}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec syncing_status() -> boolean().
syncing_status() ->
    %% this should be a call so we don't loose state
    gen_server:call(?MODULE, syncing_status, infinity).

handoff_consensus(ConsensusGroup, Members, ProofBlock) ->
    gen_server:call(?MODULE, {handoff_consensus, ConsensusGroup,
                              Members, ProofBlock},
                    infinity).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    Curve = proplists:get_value(curve, Args),
    BlockTime = proplists:get_value(block_time, Args),
    BatchSize = proplists:get_value(batch_size, Args),
    %% TODO: move this into the the chain
    Interval = proplists:get_value(election_interval, Args, 30),
    ok = blockchain_event:add_handler(self()),

    self() ! maybe_restore_consensus,

    {ok, #state{curve=Curve,
                block_time=BlockTime,
                batch_size=BatchSize,
                election_interval = Interval}}.

handle_call(pubkey_bin, _From, State) ->
    Swarm = blockchain_swarm:swarm(),
    {reply, libp2p_swarm:pubkey_bin(Swarm), State};
handle_call({add_gateway_txn, Owner, Fee, Amount}, _From, State=#state{}) ->
    {ok, PubKey, SigFun} =  libp2p_swarm:keys(blockchain_swarm:swarm()),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Txn = blockchain_txn_add_gateway_v1:new(Owner, PubKeyBin, Amount, Fee),
    SignedTxn = blockchain_txn_add_gateway_v1:sign_request(Txn, SigFun),
    {reply, {ok, blockchain_txn:serialize(SignedTxn)}, State};
handle_call({assert_loc_txn, H3Index, Owner, Nonce, Fee}, _From, State=#state{}) ->
    {ok, PubKey, SigFun} =  libp2p_swarm:keys(blockchain_swarm:swarm()),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Txn = blockchain_txn_assert_location_v1:new(PubKeyBin, Owner, H3Index, Nonce, Fee),
    SignedTxn = blockchain_txn_assert_location_v1:sign_request(Txn, SigFun),
    {reply, {ok, blockchain_txn:serialize(SignedTxn)}, State};
handle_call({initial_dkg, GenesisTransactions, Addrs}, From, State) ->
    case do_initial_dkg(GenesisTransactions, Addrs, State) of
        {true, DKGState} ->
            lager:info("Waiting for DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {noreply, DKGState#state{dkg_await=From}};
        {false, NonDKGState} ->
            lager:info("Not running DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:pubkey_bin()]),
            {reply, ok, NonDKGState}
    end;
handle_call(consensus_pos, _From, State) ->
    {reply, State#state.consensus_pos, State};
handle_call(consensus_group, _From, State) ->
        {reply, State#state.consensus_group, State};
handle_call(dkg_group, _From, State) ->
        {reply, State#state.dkg_group, State};
handle_call({create_block, Stamps, Transactions, HBBFTRound},
            _From,
            #state{blockchain=Chain}=State) when Chain /= undefined ->
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    %% we expect every stamp to contain the same block hash
    case lists:usort([ X || {_, {_, X}} <- Stamps ]) of
        [CurrentBlockHash] ->
            SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Transactions),
            %% populate this from the last block, unless the last block was the genesis block in which case it will be 0
            LastBlockTimestamp = blockchain_block:time(CurrentBlock),
            BlockTime = miner_util:median([ X || {_, {X, _}} <- Stamps, X > LastBlockTimestamp]),
            lager:info("new block time is ~p", [BlockTime]),
            TempBlock = blockchain_block_v1:new(#{prev_hash => CurrentBlockHash,
                                                  height => blockchain_block:height(CurrentBlock) + 1,
                                                  transactions => [],
                                                  signatures => [],
                                                  hbbft_round => HBBFTRound,
                                                  time => BlockTime}),
            {ValidTransactions, InvalidTransactions} = blockchain_txn:validate(SortedTransactions, TempBlock, blockchain:ledger(Chain)),
            NewBlock = blockchain_block_v1:new(#{prev_hash => CurrentBlockHash,
                                                 height => blockchain_block:height(CurrentBlock) + 1,
                                                 transactions => ValidTransactions,
                                                 signatures => [],
                                                 hbbft_round => HBBFTRound,
                                                 time => BlockTime}),
            {ok, MyPubKey, SignFun} = blockchain_swarm:keys(),
            BinNewBlock = blockchain_block:serialize(NewBlock),
            Signature = SignFun(BinNewBlock),
            %% XXX: can we lose state here if we crash and recover later?
            lager:info("Worker:~p, Created Block: ~p, Txns: ~p", [self(), NewBlock, ValidTransactions]),
            %% return both valid and invalid transactions to be deleted from the buffer
            {reply, {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock, Signature, ValidTransactions ++ InvalidTransactions}, State};
        [_OtherBlockHash] ->
            {reply, {error, stale_hash}, State};
        List ->
            lager:warning("got unexpected block hashes in stamp information ~p", [List]),
            {reply, {error, multiple_hashes}, State}
    end;
handle_call({signed_block, Signatures, Tempblock}, _From,
            State=#state{consensus_group = ConsensusGroup,
                         blockchain = Chain,
                         block_time = BlockTime}) when ConsensusGroup /= undefined ->
    %% Once a miner gets a sign_block message (only happens if the miner is in consensus group):
    %% * cancel the block timer
    %% * sign the block
    %% * tell hbbft to go to next round
    %% * add the block to blockchain
    Block = blockchain_block:set_signatures(blockchain_block:deserialize(Tempblock), Signatures),
    case blockchain:add_block(Block, Chain) of
        ok ->
            erlang:cancel_timer(State#state.block_timer),
            Ref = set_next_block_timer(Chain, BlockTime),
            lager:info("sending the gossiped block to other workers"),
            Swarm = blockchain_swarm:swarm(),
            libp2p_group_gossip:send(
              libp2p_swarm:gossip_group(Swarm),
              ?GOSSIP_PROTOCOL,
              blockchain_gossip_handler:gossip_data(Swarm, Block)
             ),
            {reply, ok, State#state{block_timer=Ref}};
        Error ->
            lager:error("signed_block, error: ~p", [Error]),
            {reply, ok, State}
    end;
handle_call(in_consensus, _From, #state{consensus_pos=Pos}=State) ->
    Reply = case Pos of
                undefined -> false;
                _ -> true
            end,
    {reply, Reply, State};
handle_call({sign_genesis_block, GenesisBlock, _PrivateKey}, _From, State) ->
    {ok, MyPubKey, SignFun} = blockchain_swarm:keys(),
    Signature = SignFun(GenesisBlock),
    Address = libp2p_crypto:pubkey_to_bin(MyPubKey),
    {reply, {ok, Address, Signature}, State};
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, Members, PrivKey}, _From,
            #state{batch_size = BatchSize,
                   block_time = BlockTime} = State) ->
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
    %% TODO generate a unique value (probably based on the public key from the DKG) to identify
    %% this consensus group
    Ref = erlang:send_after(BlockTime, self(), block_timeout),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus_1",
                                         libp2p_group_relcast, GroupArg),
    lager:info("~p. Group: ~p~n", [self(), Group]),
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(), Group]}),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    {reply, ok, State#state{consensus_group = Group,
                            block_timer = Ref,
                            dkg_await = undefined, % not sure we use this again, but
                            current_height = 0,
                            blockchain = Chain}};
handle_call({election_done, BinaryBlock, Signatures, Members, PrivKey}, _From,
            State = #state{consensus_group = OldGroup,
                           batch_size = BatchSize,
                           block_time = BlockTime,
                           blockchain = Chain,
                           current_height = CurrHeight}) ->
    lager:info("election done at ~p", [CurrHeight]),

    Block = blockchain_block:set_signatures(blockchain_block:deserialize(BinaryBlock), Signatures),

    ok = blockchain:add_block(Block, Chain),
    Height = blockchain_block:height(Block),
    Swarm = blockchain_swarm:swarm(),
    Address = blockchain_swarm:pubkey_bin(),
    libp2p_group_gossip:send(
      libp2p_swarm:gossip_group(Swarm),
      ?GOSSIP_PROTOCOL,
      term_to_binary({block, Address, Block})
     ),
    ok = blockchain_worker:notify({add_block, blockchain_block:hash_block(Block), true}),

    N = blockchain_worker:num_consensus_members(),
    F = ((N - 1) div 3),

    %% grab the existing transactions on this node, if any
    Buf =
        case OldGroup of
            P when is_pid(P) ->
                case is_process_alive(P) of
                    true ->
                        {ok, B} = libp2p_group_relcast:handle_command(P, get_buf),
                        B;
                    false ->
                        []
                end;
            _ ->
                []
        end,

    Chain = blockchain_worker:blockchain(),
    GroupArg = [miner_hbbft_handler, [Members,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain,
                                      Height,
                                      Buf]],
    Ref = set_next_block_timer(Chain, BlockTime),
    Name = "consensus_" ++ integer_to_list(max(0, Height)),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                         Name,
                                         libp2p_group_relcast, GroupArg),
    lager:info("post-election start group ~p ~p in pos ~p", [Name, Group, State#state.consensus_pos]),
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(), Group]}),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    {reply, ok, State#state{consensus_group = Group,
                            block_timer = Ref,
                            current_height = Height,
                            blockchain = Chain}};

handle_call(syncing_status, _From, #state{currently_syncing=Status}=State) ->
    {reply, Status, State};
handle_call({handoff_consensus, NewConsensusGroup, Members, ProofBlock}, From,
            State) ->
    %% this is annoyingly async and tricky.
    %% 0. validate proof block against members
    %% 1. Set a state flag
    %% 2. add block to unconditionally add
    %% 3. case waiting: start unconditional round
    %%         in progress: return to loop

    case libp2p_group_relcast:handle_call(State#state.consensus_group,
                                          {unconditional_start, new_group_block(Members)}) of
        {_, already_started} ->
            %% try again after the next block finishes.

    {noreply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

%% TODO: how to restore state when consensus group changes
%% presumably if there's a crash and the consensus members changed, this becomes pointless
handle_info(maybe_restore_consensus, State=#state{election_interval=Interval}) ->
    Chain = blockchain_worker:blockchain(),
    case Chain of
        undefined ->
            {noreply, State};
        Chain ->
            {ok, Height} = blockchain:height(Chain),
            case Height rem Interval == 0 andalso Height /= 0 of
                true ->
                    %% Restore an election round
                    {ok, Hash} = blockchain:head_hash(Chain),
                    {noreply, initiate_election(Chain, Hash, Height, State)};
                false ->
                    Ledger = blockchain:ledger(Chain),
                    case blockchain_ledger_v1:consensus_members(Ledger) of
                        {error, _} ->
                            {noreply, State#state{blockchain=Chain}};
                        {ok, ConsensusAddrs} ->
                            case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
                                true ->
                                    lager:info("restoring consensus group"),
                                    Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
                                    N = length(ConsensusAddrs),
                                    F = (N div 3),
                                    GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
                                                                      Pos,
                                                                      N,
                                                                      F,
                                                                      State#state.batch_size,
                                                                      undefined,
                                                                      Chain]],
                                    Ref = set_next_block_timer(Chain, State#state.block_time),
                                    Name = "consensus_" ++ integer_to_list(max(0, Height + 1 - (Height rem Interval))),
                                    lager:info("Restoring consensus group ~s", [Name]),
                                    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), Name, libp2p_group_relcast, GroupArg),
                                    lager:info("~p. Group: ~p~n", [self(), Group]),
                                    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                                                         {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
                                    {noreply, State#state{consensus_group=Group, block_timer=Ref, consensus_pos=Pos, blockchain=Chain}};
                                false ->
                                    {noreply, State#state{blockchain=Chain}}
                            end
                    end
            end
    end;
handle_info(block_timeout, State) ->
    lager:info("block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    {noreply, State};
handle_info({blockchain_event, {add_block, Hash, Sync}},
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         blockchain = Chain,
                         block_time = BlockTime,
                         handoff_waiting = Waiting}) when ConsensusGroup /= undefined andalso
                                                          Chain /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
    lager:info("add block ~p", [Hash]),

    NewState =
        case blockchain:get_block(Hash, Chain) of
            {ok, Block} ->
                case blockchain_block:height(Block) of
                    Height when Height > CurrHeight ->
                        erlang:cancel_timer(State#state.block_timer),
                        lager:info("processing block for ~p", [Height]),
                        case Waiting of
                            no ->
                                Round = blockchain_block:hbbft_round(Block) + 1,
                                NextRound = Round + 1,
                                case Height > (Start + Interval) of
                                    false ->
                                        libp2p_group_relcast:handle_input(
                                          ConsensusGroup, {next_round, NextRound,
                                                           blockchain_block:transactions(Block),
                                                           Sync}),
                                        Ref = set_next_block_timer(Chain, BlockTime),
                                        State#state{block_timer = Ref,
                                                    current_height = Height};
                                    %% this consensus group has aged out.  for the first draft, we
                                    %% grab the block hash and convert it into an integer to use as a
                                    %% seed for the random operations that come next.  Then, we use
                                    %% that to select a new consensus group deterministically (ish).
                                    true ->
                                        case erlang:whereis(miner_election_mgr) of
                                            undefined ->
                                                %% election isn't running, start one
                                                miner_sup:start_election(Chain, Hash, Height, State);
                                            _ ->
                                                %% election running
                                                %% signal the existing group to stop.
                                        end
                                end;
                            {next_block, Txns} ->
                                %% unconditionally start a new round with these txns
                                



                                ok = libp2p_group_relcast:handle_input(ConsensusGroup, stop),

                                initiate_election(Chain, Hash, Height, State)
                        end;
                    _Height ->
                        lager:info("skipped re-processing block for ~p", [_Height]),
                        State
                end;
            {error, Reason} ->
                lager:error("Error, Reason: ~p", [Reason]),
                State
        end,
    {noreply, signal_syncing_status(Sync, NewState)};
handle_info({blockchain_event, {add_block, Hash, Sync}},
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         blockchain = Chain}) when ConsensusGroup == undefined andalso
                                                   Chain /= undefined ->
    lager:info("non-consensus block"),
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            case blockchain_block:height(Block) of
                Height when Height > CurrHeight ->
                    lager:info("nc processing block for ~p", [Height]),
                    case Height rem Interval == 0 andalso Height /= 0 of
                        false ->
                            {noreply, signal_syncing_status(Sync, State)};
                        %% this consensus group has aged out.  for the first draft, we
                        %% grab the block hash and convert it into an integer to use as a
                        %% seed for the random operations that come next.  Then, we use
                        %% that to select a new consensus group deterministically (ish).
                        true ->
                            {noreply, signal_syncing_status(Sync, initiate_election(Chain, Hash, Height, State))}
                    end;
                _ ->
                    {noreply, signal_syncing_status(Sync, State)}
            end;
        {error, Reason} ->
            lager:error("Error, Reason: ~p", [Reason]),
            {noreply, signal_syncing_status(Sync, State)}
    end;
handle_info({blockchain_event, {add_block, _Hash, Sync}},
            State=#state{blockchain = Chain}) when Chain == undefined ->
    {noreply, signal_syncing_status(Sync, State#state{blockchain = blockchain_worker:blockchain()})};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

%% ==================================================================
%% Internal functions
%% =================================================================

-spec signal_syncing_status(boolean(), #state{}) -> #state{}.
signal_syncing_status(true, #state{currently_syncing=true}=State) ->
    State;
signal_syncing_status(true, #state{currently_syncing=false}=State) ->
    miner_ebus:send_signal("SyncingStatus", "StartSyncing"),
    State#state{currently_syncing=true};
signal_syncing_status(false, #state{currently_syncing=true}=State) ->
    miner_ebus:send_signal("SyncingStatus", "StopSyncing"),
    State#state{currently_syncing=false};
signal_syncing_status(false, #state{currently_syncing=false}=State) ->
    State.

set_next_block_timer(Chain, BlockTime) ->
    {ok, HeadBlock} = blockchain:head_block(Chain),
    LastBlockTimestamp = blockchain_block:time(HeadBlock),
    NextBlockTime = max(0, (LastBlockTimestamp + (BlockTime div 1000)) - erlang:system_time(seconds)),
    lager:info("Next block after ~p is in ~p seconds", [LastBlockTimestamp, NextBlockTime]),
    erlang:send_after(NextBlockTime * 1000, self(), block_timeout).
