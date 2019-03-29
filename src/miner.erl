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
    relcast_info/1,
    relcast_queue/1,
    hbbft_status/0,
    hbbft_skip/0,
    create_block/3,
    signed_block/2,
    syncing_status/0,

    start_chain/2,
    handoff_consensus/1,
    election_epoch/0
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
    consensus_start = 1 :: pos_integer(),
    blockchain :: undefined | blockchain:blockchain(),
    %% but every miner keeps a timer reference?
    block_timer = make_ref() :: reference(),
    cold_start :: undefined | reference(),
    try_restore = true :: boolean(),
    block_time = 15000 :: number(),
    currently_syncing = false :: boolean(),
    election_interval :: pos_integer(),
    current_height = -1 :: integer(),
    handoff_waiting :: undefined | pid() | {pending, [binary()], pos_integer(), blockchain_block:block(), boolean()},
    election_epoch = 1 :: pos_integer()
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
    Mod = case Group of
              dkg_group ->
                  miner_consensus_mgr;
              _ ->
                  ?MODULE
          end,
    case gen_server:call(Mod, Group, 60000) of
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
-spec signed_block([binary()], binary()) -> ok.
signed_block(Signatures, BinBlock) ->
    %% Once a miner gets a sign_block message (only happens if the miner is in consensus group):
    %% * cancel the block timer
    %% * sign the block
    %% * tell hbbft to go to next round
    %% * add the block to blockchain
    Chain = blockchain_worker:blockchain(),
    Block = blockchain_block:set_signatures(blockchain_block:deserialize(BinBlock), Signatures),
    case blockchain:add_block(Block, Chain) of
        ok ->
            lager:info("sending the gossiped block to other workers"),
            Swarm = blockchain_swarm:swarm(),
            libp2p_group_gossip:send(
              libp2p_swarm:gossip_group(Swarm),
              ?GOSSIP_PROTOCOL,
              blockchain_gossip_handler:gossip_data(Swarm, Block)
             );
        Error ->
            lager:error("signed_block, error: ~p", [Error])
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec syncing_status() -> boolean().
syncing_status() ->
    %% this should be a call so we don't loose state
    gen_server:call(?MODULE, syncing_status, infinity).

start_chain(ConsensusGroup, Chain) ->
    gen_server:call(?MODULE, {start_chain, ConsensusGroup, Chain}, infinity).

handoff_consensus(ConsensusGroup) ->
    gen_server:call(?MODULE, {handoff_consensus, ConsensusGroup}, infinity).

election_epoch() ->
    gen_server:call(?MODULE, election_epoch).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    lager:info("STARTING UP MINER"),
    BlockTime = proplists:get_value(block_time, Args),
    %% TODO: move this into the the chain
    Interval = proplists:get_value(election_interval, Args, 30),
    ok = blockchain_event:add_handler(self()),
    State = #state{block_time=BlockTime,
                   election_interval = Interval},
    case blockchain_worker:blockchain() of
            undefined ->
            {ok, State};
        Chain ->
            {ok, Top} = blockchain:height(Chain),
            {ok, Block} = blockchain:get_block(Top, Chain),
            {ElectionEpoch, EpochStart} = blockchain_block_v1:election_info(Block),
            self() ! init,

            %% TODO THIS SHOULD BE 120s
            ColdStart = application:get_env(miner, cold_start_timeout_secs, 10),
            Ref = erlang:send_after(timer:seconds(ColdStart), self(), cold_start_timeout),
            {ok, State#state{blockchain = Chain,
                             cold_start = Ref,
                             election_epoch = ElectionEpoch,
                             consensus_start = EpochStart}}
    end.

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
handle_call(consensus_group, _From, State) ->
    {reply, State#state.consensus_group, State};
handle_call(syncing_status, _From, #state{currently_syncing=Status}=State) ->
    {reply, Status, State};
handle_call({handoff_consensus, NewConsensusGroup}, _From,
            #state{handoff_waiting = Waiting} = State) ->
    lager:info("handing off consensus from ~p or ~p to ~p",
               [State#state.consensus_group,
                Waiting,
                NewConsensusGroup]),
    {Group, Waiting1} =
        case Waiting of
            Pid when is_pid(Pid) ->
                %% stale, kill it
                catch libp2p_group_relcast:handle_command(Pid, {stop, 0}),
                {State#state.consensus_group, Waiting};
            %% here, we've already transitioned, so do the handoff
            {pending, Buf, NextRound, Block, Sync} ->
                set_buf(NewConsensusGroup, Buf),
                libp2p_group_relcast:handle_input(
                  NewConsensusGroup, {next_round, NextRound,
                                      blockchain_block:transactions(Block),
                                      Sync}),
                start_txn_handler(NewConsensusGroup),
                {NewConsensusGroup, undefined};
            _ ->
                {State#state.consensus_group, NewConsensusGroup}
        end,
    lager:info("NEW ~p", [{Group, Waiting1}]),
    {reply, ok, State#state{handoff_waiting = Waiting1,
                            consensus_group = Group}};
handle_call({start_chain, ConsensusGroup, Chain}, _From, State) ->
    lager:info("registering first consensus group"),
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(),
                                           ConsensusGroup]}),

    Ref = set_next_block_timer(Chain, State#state.block_time),
    {reply, ok, State#state{consensus_group = ConsensusGroup,
                            blockchain = Chain,
                            consensus_start = 1,
                            election_epoch = 1,
                            try_restore = false,
                            block_timer = Ref}};
handle_call({create_block, Stamps, Txns, HBBFTRound}, _From,
            #state{election_epoch = ElectionEpoch0,
                   consensus_start = EpochStart0} = State) ->
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    Chain = blockchain_worker:blockchain(),
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    %% we expect every stamp to contain the same block hash
    Reply =
        case lists:usort([ X || {_, {_, X}} <- Stamps ]) of
            [CurrentBlockHash] ->
                SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Txns),
                NewHeight = blockchain_block:height(CurrentBlock) + 1,
                %% populate this from the last block, unless the last block was the genesis
                %% block in which case it will be 0
                LastBlockTimestamp = blockchain_block:time(CurrentBlock),
                BlockTime = miner_util:median([ X || {_, {X, _}} <- Stamps,
                                                     X > LastBlockTimestamp]),
                FakeBlock = blockchain_block_v1:new(
                             #{prev_hash => CurrentBlockHash,
                               height => NewHeight,
                               transactions => [],
                               signatures => [],
                               hbbft_round => HBBFTRound,
                               time => BlockTime,
                               election_epoch => 1,
                               epoch_start => 0}),
                {ValidTransactions, InvalidTransactions} =
                    blockchain_txn:validate(SortedTransactions, FakeBlock, blockchain:ledger(Chain)),
                {ElectionEpoch, EpochStart} =
                    case has_new_group(ValidTransactions) of
                        {true, _} ->
                            {ElectionEpoch0 + 1, NewHeight};
                        _ ->
                            {ElectionEpoch0, EpochStart0}
                    end,
                lager:info("new block time is ~p", [BlockTime]),
                NewBlock = blockchain_block_v1:new(
                             #{prev_hash => CurrentBlockHash,
                               height => NewHeight,
                               transactions => ValidTransactions,
                               signatures => [],
                               hbbft_round => HBBFTRound,
                               time => BlockTime,
                               election_epoch => ElectionEpoch,
                               epoch_start => EpochStart}),
                lager:info("newblock ~p", [NewBlock]),
                {ok, MyPubKey, SignFun} = blockchain_swarm:keys(),
                BinNewBlock = blockchain_block:serialize(NewBlock),
                Signature = SignFun(BinNewBlock),
                %% XXX: can we lose state here if we crash and recover later?
                lager:info("Worker:~p, Created Block: ~p, Txns: ~p",
                           [self(), NewBlock, ValidTransactions]),
                %% return both valid and invalid transactions to be deleted from the buffer
                {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock,
                 Signature, ValidTransactions ++ InvalidTransactions};
            [_OtherBlockHash] ->
                {error, stale_hash};
            List ->
                lager:warning("got unexpected block hashes in stamp information ~p", [List]),
                {error, multiple_hashes}
        end,
    {reply, Reply, State};
handle_call(election_epoch, _From, State) ->
    {reply, State#state.election_epoch, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {noreply, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info(block_timeout, State) when State#state.consensus_group == undefined ->
    {noreply, State};
handle_info(block_timeout, State) ->
    lager:info("block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    {noreply, State};
handle_info({blockchain_event, {add_block, Hash, Sync}},
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         consensus_start = Start,
                         blockchain = Chain,
                         block_time = BlockTime,
                         handoff_waiting = Waiting,
                         election_epoch = Epoch}) when ConsensusGroup /= undefined andalso
                                                       Chain /= undefined ->
    cancel_cold_start(State#state.cold_start),
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
    lager:info("add block @ ~p ~p ~p", [ConsensusGroup, Start, Epoch]),

    NewState =
        case blockchain:get_block(Hash, Chain) of
            {ok, Block} ->
                case blockchain_block:height(Block) of
                    Height when Height > CurrHeight ->
                        erlang:cancel_timer(State#state.block_timer),
                        lager:info("processing block for ~p", [Height]),
                        Round = blockchain_block:hbbft_round(Block),
                        Txns = blockchain_block:transactions(Block),
                        case has_new_group(Txns) of
                            %% not here yet, regular round
                            false ->
                                lager:info("reg round"),
                                NextElection = Start + Interval,
                                miner_consensus_mgr:maybe_start_election(Hash, Height, NextElection),
                                NextRound = Round + 1,
                                libp2p_group_relcast:handle_input(
                                  ConsensusGroup, {next_round, NextRound,
                                                   blockchain_block:transactions(Block),
                                                   Sync}),
                                State#state{block_timer = set_next_block_timer(Chain, BlockTime),
                                            current_height = Height};
                            %% there's a new group now, and we're still in, so pass over the
                            %% buffer, shut down the old one and elevate the new one
                            {true, true} ->
                                %% it's possible that waiting hasn't been set, I'm not entirely
                                %% sure how to handle that at this point
                                lager:info("stay in ~p", [Waiting]),
                                Buf = get_buf(ConsensusGroup),
                                NextRound = Round + 1,

                                {NewGroup, Waiting1} =
                                    case Waiting of
                                        Pid when is_pid(Pid) ->
                                            set_buf(Waiting, Buf),
                                            libp2p_group_relcast:handle_input(
                                              Waiting, {next_round, NextRound,
                                                        blockchain_block:transactions(Block),
                                                        Sync}),
                                            start_txn_handler(Waiting),
                                            {Waiting, undefined};
                                        undefined ->
                                            {undefined, %% shouldn't be too harmful to kick onto nc track for a bit
                                             {pending, Buf, NextRound, Block, Sync}}
                                    end,
                                catch libp2p_group_relcast:handle_command(ConsensusGroup, stop),
                                lager:info("got here"),
                                State#state{block_timer = set_next_block_timer(Chain, BlockTime),
                                            handoff_waiting = Waiting1,
                                            consensus_group = NewGroup,
                                            election_epoch = State#state.election_epoch + 1,
                                            current_height = Height,
                                            consensus_start = Height,
                                            try_restore = false};
                            %% we're not a member of the new group, we can shut down
                            {true, false} ->
                                lager:info("leave"),

                                catch libp2p_group_relcast:handle_command(ConsensusGroup, stop),

                                State#state{block_timer = make_ref(),
                                            handoff_waiting = undefined,
                                            consensus_group = undefined,
                                            election_epoch = State#state.election_epoch + 1,
                                            consensus_start = Height,
                                            current_height = Height,
                                            try_restore = false}
                            end;
                    _Height ->
                        lager:info("skipped re-processing block for ~p", [_Height]),
                        State
                end;
            {error, Reason} ->
                lager:error("Error, Reason: ~p", [Reason]),
                State
        end,
    {noreply, signal_syncing_status(Sync, NewState#state{cold_start = undefined})};
handle_info({blockchain_event, {add_block, Hash, Sync}} = Event,
            State = #state{consensus_group = ConsensusGroup,
                           election_interval = Interval,
                           consensus_start = Start,
                           election_epoch = Epoch,
                           try_restore = Restore,
                           blockchain = Chain}) when ConsensusGroup == undefined andalso
                                                     Chain /= undefined andalso
                                                     Sync == false andalso
                                                     Restore == true ->
    cancel_cold_start(State#state.cold_start),
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            Height = blockchain_block:height(Block),
            lager:info("non-consensus restore check ~p @ ~p ~p", [Height, Start, Epoch]),
            %% if none of this stuff is set and we're no longer
            %% syncing, we might need to start a consensus group
            Group = restore(Chain, Block, Height, Interval),
            handle_info(Event, State#state{try_restore = false,
                                           consensus_group = Group,
                                           cold_start = undefined});
        _ ->
            handle_info(Event, State#state{cold_start = undefined})
        end;
handle_info({blockchain_event, {add_block, Hash, Sync}},
            #state{consensus_group = ConsensusGroup,
                   election_interval = Interval,
                   current_height = CurrHeight,
                   consensus_start = Start,
                   handoff_waiting = Waiting,
                   election_epoch = Epoch,
                   blockchain = Chain} = State) when ConsensusGroup == undefined andalso
                                                     Chain /= undefined ->
    cancel_cold_start(State#state.cold_start),
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            Height = blockchain_block:height(Block),
            lager:info("non-consensus block ~p @ ~p ~p", [Height, Start, Epoch]),
            case Height of
                H when H > CurrHeight ->
                    lager:info("nc processing block for ~p", [Height]),
                    Txns = blockchain_block:transactions(Block),
                    case has_new_group(Txns) of
                        false ->
                            lager:info("nc reg round"),
                            NextElection = Start + Interval,
                            miner_consensus_mgr:maybe_start_election(Hash, Height, NextElection),
                            {noreply, signal_syncing_status(Sync, State#state{current_height = Height})};
                        {true, true} ->
                            lager:info("nc start group"),
                            %% it's possible that waiting hasn't been set, I'm not entirely
                            %% sure how to handle that at this point
                            Round = blockchain_block:hbbft_round(Block),
                            NextRound = Round + 1,
                            {NewGroup, Waiting1} =
                                case Waiting of
                                    Pid when is_pid(Pid) ->
                                        libp2p_group_relcast:handle_input(
                                          Waiting, {next_round, NextRound,
                                                    blockchain_block:transactions(Block),
                                                    Sync}),
                                        start_txn_handler(Waiting),
                                        {Waiting, undefined};
                                    undefined ->
                                        {undefined, %% shouldn't be too harmful to kick onto nc track for a bit
                                         {pending, [], NextRound, Block, Sync}}
                                end,
                            lager:info("nc got here"),
                            {noreply,
                             State#state{block_timer = set_next_block_timer(Chain, State#state.block_time),
                                         handoff_waiting = Waiting1,
                                         consensus_group = NewGroup,
                                         election_epoch = State#state.election_epoch + 1,
                                         current_height = Height,
                                         consensus_start = Height,
                                         try_restore = false}};
                        %% we're not a member of the new group, we can stay down
                        {true, false} ->
                            lager:info("nc stay out"),

                            {noreply,
                             State#state{block_timer = make_ref(),
                                         handoff_waiting = undefined,
                                         consensus_group = undefined,
                                         election_epoch = State#state.election_epoch + 1,
                                         current_height = Height,
                                         consensus_start = Height,
                                         try_restore = false}}
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
handle_info(init, #state{consensus_group = OldGroup, blockchain = Chain} = State) ->
    {ok, ConsensusHeight} = blockchain_ledger_v1:election_height(blockchain:ledger(Chain)),
    Group =
        case OldGroup of
            undefined ->
                G = miner_consensus_mgr:maybe_start_consensus_group(ConsensusHeight),
                start_txn_handler(G),
                G;
            P when is_pid(P) ->
                P
        end,
    {noreply, State#state{consensus_group = Group}};
handle_info(cold_start_timeout, #state{election_interval = Interval} = State) ->
    %% here we assume that we've gotten no input for some large number
    %% of seconds after start, so we go into cold start mode, assuming
    %% that the last block that we know about is actually the last
    %% block, and that the whole network may be waiting.
    Chain = blockchain_worker:blockchain(),
    case Chain == undefined of
        true ->
            {noreply, State};
        false ->
            {ok, Height} = blockchain:height(Chain),
            lager:info("cold start blockchain at known height ~p", [Height]),
            {ok, Block} = blockchain:get_block(Height, Chain),
            Group = restore(Chain, Block, Height, Interval),
            {noreply, State#state{blockchain = Chain,
                                  consensus_group = Group}}
    end;
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

%% ==================================================================
%% Internal functions
%% =================================================================

restore(Chain, Block, Height, Interval) ->
    lager:info("attempting to restore"),
    {_ElectionEpoch, EpochStart} = blockchain_block_v1:election_info(Block),
    {ok, ConsensusHeight} = blockchain_ledger_v1:election_height(blockchain:ledger(Chain)),
    Group = miner_consensus_mgr:maybe_start_consensus_group(ConsensusHeight),
    start_txn_handler(Group),
    case Height of
        %% it's possible that we've already processed the block that would
        %% have started the election, so try this on restore
        Ht when Ht > (EpochStart + Interval) ->
            {ok, ElectionBlock} = blockchain:get_block(EpochStart + Interval, Chain),
            EHash = blockchain_block:hash_block(ElectionBlock),
            miner_consensus_mgr:start_election(EHash, EpochStart + Interval);
        _ ->
            ok
    end,
    Group.

%% TODO: rip this out.  we should update the flag at the start of
%% add-block events and then pass the state through normally, this
%% action should be taken via asynchronous tick to control the rate at
%% which we talk to dbus
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

has_new_group(Txns) ->
    lager:info("has new group called with ~p",[Txns]),
    MyAddress = blockchain_swarm:pubkey_bin(),
    case lists:filter(fun(T) ->
                              %% TODO: ideally move to versionless types?
                              lager:info("txn type ~p", [blockchain_txn:type(T)]),
                              blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                      end, Txns) of
        [Txn] ->
            lager:info("has new group, ~p ~p", [MyAddress, blockchain_txn_consensus_group_v1:members(Txn)]),
            {true, lists:member(MyAddress, blockchain_txn_consensus_group_v1:members(Txn))};
        [_|_] ->
            lists:foreach(fun(T) ->
                                  case blockchain_txn:type(T) == blockchain_txn_consensus_group_v1 of
                                      true ->
                                          lager:info("txn ~p", [T]);
                                      _ -> ok
                                  end
                          end, Txns),
            error(duplicate_group_txn);
        [] ->
            false
    end.

cancel_cold_start(undefined) ->
    ok;
cancel_cold_start(Ref) ->
    erlang:cancel_timer(Ref).

start_txn_handler(undefined) ->
    ok;
start_txn_handler(Group) ->
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(), Group]}).
