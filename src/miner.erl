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

    start_chain/2,
    handoff_consensus/1,
    election_epoch/0,
    version/0
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
    election_interval = infinity :: pos_integer() | infinity,
    current_height = -1 :: integer(),
    handoff_waiting :: undefined | pid() | {pending, [binary()], pos_integer(), blockchain_block:block(), boolean()},
    election_epoch = 1 :: pos_integer()
}).

-define(H3_MINIMUM_RESOLUTION, 9).

-include_lib("blockchain/include/blockchain.hrl").

-ifdef(TEST).

-define(tv, '$test_version').
-define(v, '$value').

-export([test_version/0, inc_tv/1]).

test_version() ->
    case ets:info(?tv) of
        undefined ->
            ets:new(?tv, [named_table, public]),
            ets:insert(?tv, {?tv, 1}),
            1;
        _ ->
            [{_, V}] = ets:lookup(?tv, ?tv),
            V
    end.

inc_tv(Incr) ->
    case ets:info(?tv) of
        undefined ->
            ets:new(?tv, [named_table, public]),
            ets:insert(?tv, {?tv, 1}),
            1;
        _ ->
            ets:update_counter(?tv, ?tv, Incr)
    end.

-endif.

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
    Mod = case Group of
              dkg_group ->
                  miner_consensus_mgr;
              _ ->
                  ?MODULE
          end,
    case gen_server:call(Mod, Group, 60000) of
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

start_chain(ConsensusGroup, Chain) ->
    gen_server:call(?MODULE, {start_chain, ConsensusGroup, Chain}, infinity).

handoff_consensus(ConsensusGroup) ->
    gen_server:call(?MODULE, {handoff_consensus, ConsensusGroup}, infinity).

election_epoch() ->
    gen_server:call(?MODULE, election_epoch).

-spec version() -> integer().
version() ->
    1.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    lager:info("STARTING UP MINER"),
    ok = blockchain_event:add_handler(self()),
    case blockchain_worker:blockchain() of
        undefined ->
            {ok, #state{}};
        Chain ->
            {ok, Top} = blockchain:height(Chain),
            {ok, Block} = blockchain:get_block(Top, Chain),
            {ElectionEpoch, EpochStart} = blockchain_block_v1:election_info(Block),
            Ledger = blockchain:ledger(Chain),
            {ok, Interval} = blockchain:config(election_interval, Ledger),
            self() ! init,

            {ok, #state{blockchain = Chain,
                        election_epoch = ElectionEpoch,
                        consensus_start = EpochStart,
                        election_interval = Interval}}
    end.

handle_call(pubkey_bin, _From, State) ->
    Swarm = blockchain_swarm:swarm(),
    {reply, libp2p_swarm:pubkey_bin(Swarm), State};
handle_call({add_gateway_txn, Owner, Fee, Amount}, _From, State=#state{}) ->
    {ok, PubKey, SigFun, _ECDHFun} =  libp2p_swarm:keys(blockchain_swarm:swarm()),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Txn = blockchain_txn_add_gateway_v1:new(Owner, PubKeyBin, Amount, Fee),
    SignedTxn = blockchain_txn_add_gateway_v1:sign_request(Txn, SigFun),
    {reply, {ok, blockchain_txn:serialize(SignedTxn)}, State};
handle_call({assert_loc_txn, H3Index, Owner, Nonce, Fee}, _From, State=#state{}) ->
    {ok, PubKey, SigFun, _ECDHFun} =  libp2p_swarm:keys(blockchain_swarm:swarm()),
    PubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    Txn = blockchain_txn_assert_location_v1:new(PubKeyBin, Owner, H3Index, Nonce, Fee),
    SignedTxn = blockchain_txn_assert_location_v1:sign_request(Txn, SigFun),
    {reply, {ok, blockchain_txn:serialize(SignedTxn)}, State};
handle_call(consensus_group, _From, State) ->
    {reply, State#state.consensus_group, State};
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
                stop_group(Pid),
                {State#state.consensus_group, NewConsensusGroup};
            %% here, we've already transitioned, so do the handoff
            {pending, Buf, NextRound, Block, Sync} ->
                set_buf(NewConsensusGroup, Buf),
                stop_group(State#state.consensus_group),
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

    Ledger = blockchain:ledger(Chain),
    {ok, Interval} = blockchain:config(election_interval, Ledger),

    Ref = set_next_block_timer(Chain),
    {reply, ok, State#state{consensus_group = ConsensusGroup,
                            blockchain = Chain,
                            consensus_start = 1,
                            election_epoch = 1,
                            block_timer = Ref,
                            election_interval = Interval}};
handle_call({create_block, Stamps, Txns, HBBFTRound}, _From,
            #state{election_epoch = ElectionEpoch0,
                   consensus_start = EpochStart0} = State) ->
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    Chain = blockchain_worker:blockchain(),
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    lager:info("stamps ~p, current hash ~p", [Stamps, CurrentBlockHash]),
    %% we expect every stamp to contain the same block hash
    Reply =
        case lists:usort([ X || {_, {_, X}} <- Stamps ]) of
            [CurrentBlockHash] ->
                SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Txns),
                CurrentBlockHeight = blockchain_block:height(CurrentBlock),
                NewHeight = CurrentBlockHeight + 1,
                %% populate this from the last block, unless the last block was the genesis
                %% block in which case it will be 0
                LastBlockTimestamp = blockchain_block:time(CurrentBlock),
                BlockTime = miner_util:median([ X || {_, {X, _}} <- Stamps,
                                                     X > LastBlockTimestamp]),
                {ValidTransactions, InvalidTransactions} =
                    blockchain_txn:validate(SortedTransactions, Chain),
                %% is there some cheaper way to do this?  maybe it's
                %% cheap enough?
                {ElectionEpoch, EpochStart, TxnsToInsert} =
                    case blockchain_election:has_new_group(ValidTransactions) of
                        {true, _} ->
                            Epoch = ElectionEpoch0 + 1,
                            Start = EpochStart0 + 1,
                            End = CurrentBlockHeight,
                            {ok, Rewards} = blockchain_txn_rewards_v1:calculate_rewards(Start, End, Chain),
                            lager:info("Rewards: ~p~n", [Rewards]),
                            RewardsTxn = blockchain_txn_rewards_v1:new(Start, End, Rewards),
                            [ConsensusGroupTxn] = lists:filter(fun(T) ->
                                                                       blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                                                               end, ValidTransactions),
                            {Epoch, NewHeight, lists:sort(fun blockchain_txn:sort/2, [RewardsTxn, ConsensusGroupTxn])};
                        _ ->
                            {ElectionEpoch0, EpochStart0, ValidTransactions}
                    end,
                lager:info("new block time is ~p", [BlockTime]),
                NewBlock = blockchain_block_v1:new(
                             #{prev_hash => CurrentBlockHash,
                               height => NewHeight,
                               transactions => TxnsToInsert,
                               signatures => [],
                               hbbft_round => HBBFTRound,
                               time => BlockTime,
                               election_epoch => ElectionEpoch,
                               epoch_start => EpochStart}),
                lager:debug("newblock ~p", [NewBlock]),
                {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
                BinNewBlock = blockchain_block:serialize(NewBlock),
                Signature = SignFun(BinNewBlock),
                %% XXX: can we lose state here if we crash and recover later?
                lager:info("Worker:~p, Created Block: ~p, Txns: ~p",
                           [self(), NewBlock, TxnsToInsert]),
                %% return both valid and invalid transactions to be deleted from the buffer
                {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock,
                 Signature, TxnsToInsert ++ InvalidTransactions};
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
handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         consensus_start = Start,
                         blockchain = Chain,
                         handoff_waiting = Waiting,
                         election_epoch = Epoch}) when ConsensusGroup /= undefined andalso
                                                       Chain /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
    lager:info("add block @ ~p ~p ~p", [ConsensusGroup, Start, Epoch]),
    Ledger = blockchain:ledger(Chain),

    NewState =
        case blockchain:get_block(Hash, Chain) of
            {ok, Block} ->
                case blockchain_block:height(Block) of
                    Height when Height > CurrHeight ->
                        erlang:cancel_timer(State#state.block_timer),
                        lager:info("processing block for ~p", [Height]),
                        Round = blockchain_block:hbbft_round(Block),
                        Txns = blockchain_block:transactions(Block),
                        case blockchain_election:has_new_group(Txns) of
                            %% not here yet, regular round
                            false ->
                                NextElection = next_election(Start, Interval),
                                lager:info("reg round c ~p n ~p", [Height, NextElection]),
                                miner_consensus_mgr:maybe_start_election(Hash, Height, NextElection),
                                NextRound = Round + 1,
                                libp2p_group_relcast:handle_input(
                                  ConsensusGroup, {next_round, NextRound,
                                                   blockchain_block:transactions(Block),
                                                   Sync}),
                                State#state{block_timer = set_next_block_timer(Chain),
                                            current_height = Height};
                            %% there's a new group now, and we're still in, so pass over the
                            %% buffer, shut down the old one and elevate the new one
                            {true, true} ->
                                {BlockEpoch, _Start} = blockchain_block_v1:election_info(Block),
                                blockchain_ledger_v1:process_epoch(BlockEpoch, blockchain:ledger(Chain)),
                                {ok, Interval} = blockchain:config(election_interval, Ledger),

                                miner_consensus_mgr:cancel_dkg(),
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
                                stop_group(ConsensusGroup),
                                State#state{block_timer = set_next_block_timer(Chain),
                                            election_interval = Interval,
                                            handoff_waiting = Waiting1,
                                            consensus_group = NewGroup,
                                            election_epoch = State#state.election_epoch + 1,
                                            current_height = Height,
                                            consensus_start = Height};
                            %% we're not a member of the new group, we can shut down
                            {true, false} ->
                                {BlockEpoch, _Start} = blockchain_block_v1:election_info(Block),
                                blockchain_ledger_v1:process_epoch(BlockEpoch, blockchain:ledger(Chain)),
                                {ok, Interval} = blockchain:config(election_interval, Ledger),

                                miner_consensus_mgr:cancel_dkg(),
                                lager:info("leave"),

                                stop_group(ConsensusGroup),

                                State#state{block_timer = make_ref(),
                                            handoff_waiting = undefined,
                                            consensus_group = undefined,
                                            election_epoch = State#state.election_epoch + 1,
                                            election_interval = Interval,
                                            consensus_start = Height,
                                            current_height = Height}
                            end;
                    _Height ->
                        lager:info("skipped re-processing block for ~p", [_Height]),
                        State
                end;
            {error, Reason} ->
                lager:error("Error, Reason: ~p", [Reason]),
                State
        end,
    {noreply, NewState};
handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            #state{consensus_group = ConsensusGroup,
                   election_interval = Interval,
                   current_height = CurrHeight,
                   consensus_start = Start,
                   handoff_waiting = Waiting,
                   election_epoch = Epoch,
                   blockchain = Chain} = State) when ConsensusGroup == undefined andalso
                                                     Chain /= undefined ->
    Ledger = blockchain:ledger(Chain),
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            Height = blockchain_block:height(Block),
            lager:info("non-consensus block ~p @ ~p ~p", [Height, Start, Epoch]),
            case Height of
                H when H > CurrHeight ->
                    lager:info("nc processing block for ~p", [Height]),
                    Txns = blockchain_block:transactions(Block),
                    case blockchain_election:has_new_group(Txns) of
                        false ->
                            lager:info("nc reg round"),
                            NextElection = next_election(Start, Interval),
                            miner_consensus_mgr:maybe_start_election(Hash, Height, NextElection),
                            {noreply, State#state{current_height = Height}};
                        {true, true} ->
                            {BlockEpoch, _Start} = blockchain_block_v1:election_info(Block),
                            blockchain_ledger_v1:process_epoch(BlockEpoch, blockchain:ledger(Chain)),
                            {ok, Interval} = blockchain:config(election_interval, Ledger),

                            lager:info("nc start group"),
                            miner_consensus_mgr:cancel_dkg(),
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
                             State#state{block_timer = set_next_block_timer(Chain),
                                         handoff_waiting = Waiting1,
                                         consensus_group = NewGroup,
                                         election_epoch = State#state.election_epoch + 1,
                                         election_interval = Interval,
                                         current_height = Height,
                                         consensus_start = Height}};
                        %% we're not a member of the new group, we can stay down
                        {true, false} ->
                            {BlockEpoch, _Start} = blockchain_block_v1:election_info(Block),
                            blockchain_ledger_v1:process_epoch(BlockEpoch, blockchain:ledger(Chain)),
                            {ok, Interval} = blockchain:config(election_interval, Ledger),

                            lager:info("nc stay out"),
                            miner_consensus_mgr:cancel_dkg(),
                            {noreply,
                             State#state{block_timer = make_ref(),
                                         handoff_waiting = undefined,
                                         consensus_group = undefined,
                                         election_epoch = State#state.election_epoch + 1,
                                         election_interval = Interval,
                                         current_height = Height,
                                         consensus_start = Height}}
                    end;

                _ ->
                    {noreply, State}
            end;
        {error, Reason} ->
            lager:error("Error, Reason: ~p", [Reason]),
            {noreply, State}
    end;
handle_info({blockchain_event, {add_block, _Hash, _Sync, _Ledger}},
            State) when State#state.blockchain == undefined ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Interval} = blockchain:config(election_interval, Ledger),

    {noreply, State#state{blockchain = Chain,
                          election_interval = Interval}};
handle_info(init, #state{blockchain = Chain} = State) ->
    {ok, Height} = blockchain:height(Chain),
    lager:info("cold start blockchain at known height ~p", [Height]),
    {ok, Block} = blockchain:get_block(Height, Chain),
    Group = restore(Chain, Block, Height, State#state.election_interval),
    Ref =
        case is_pid(Group) of
            true ->
                set_next_block_timer(Chain);
            _ ->
                undefined
        end,
    {noreply, State#state{consensus_group = Group, block_timer = Ref}};
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
    Election = next_election(EpochStart, Interval),
    case Height of
        %% it's possible that we've already processed the block that would
        %% have started the election, so try this on restore
        Ht when Ht > Election ->
            {ok, ElectionBlock} = blockchain:get_block(Election, Chain),
            EHash = blockchain_block:hash_block(ElectionBlock),
            miner_consensus_mgr:start_election(EHash, Height, Election);
        _ ->
            ok
    end,
    Group.

set_next_block_timer(Chain) ->
    {ok, BlockTime} = blockchain:config(block_time, blockchain:ledger(Chain)),
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

start_txn_handler(undefined) ->
    ok;
start_txn_handler(Group) ->
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(), Group]}).

stop_group(Pid) ->
    spawn(fun() ->
                  catch libp2p_group_relcast:handle_command(Pid, {stop, 0})
          end),
    ok.

next_election(_Base, Interval) when is_atom(Interval) ->
    infinity;
next_election(Base, Interval) ->
    Base + Interval.
