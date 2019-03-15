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
    block_time = 15000 :: number(),
    currently_syncing = false :: boolean(),
    election_interval :: pos_integer(),
    current_dkg = undefined :: undefined | pos_integer(),
    current_height = -1 :: integer(),
    handoff_waiting :: undefined | pid(),
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
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    Chain = blockchain_worker:blockchain(),
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    %% we expect every stamp to contain the same block hash
    case lists:usort([ X || {_, {_, X}} <- Stamps ]) of
        [CurrentBlockHash] ->
            SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Txns),
            {ValidTransactions, InvalidTransactions} = blockchain_txn:validate(SortedTransactions, blockchain:ledger(Chain)),
            %% populate this from the last block, unless the last block was the genesis block in which case it will be 0
            LastBlockTimestamp = blockchain_block:time(CurrentBlock),
            BlockTime = miner_util:median([ X || {_, {X, _}} <- Stamps, X > LastBlockTimestamp]),
            lager:info("new block time is ~p", [BlockTime]),
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
            {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock, Signature, ValidTransactions ++ InvalidTransactions};
        [_OtherBlockHash] ->
            {error, stale_hash};
        List ->
            lager:warning("got unexpected block hashes in stamp information ~p", [List]),
            {error, multiple_hashes}
    end.

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
             ),
            ok = blockchain_worker:notify({add_block, blockchain_block:hash_block(Block), true});
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
    BlockTime = proplists:get_value(block_time, Args),
    %% TODO: move this into the the chain
    Interval = proplists:get_value(election_interval, Args, 30),
    ok = blockchain_event:add_handler(self()),

    self() ! maybe_restore_consensus,

    {ok, #state{block_time=BlockTime,
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
handle_call(consensus_group, _From, State) ->
        {reply, State#state.consensus_group, State};
handle_call(syncing_status, _From, #state{currently_syncing=Status}=State) ->
    {reply, Status, State};
handle_call({handoff_consensus, NewConsensusGroup}, _From,
            #state{handoff_waiting = Waiting} = State) ->
    %% TODO: what happens if the block containing the thing is already synced here?
    case Waiting of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            %% stale, kill it
            libp2p_group_relcast:handle_command(Pid, {stop, 0})
    end,
    %% do we need to wait on this until the old group is gone?  assuming this is safe for now
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server,
                                          [blockchain_txn_handler, self(),
                                           NewConsensusGroup]}),
    {reply, ok, State#state{handoff_waiting = NewConsensusGroup}};
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
                            block_timer = Ref}};
handle_call(election_epoch, _From, State) ->
    {reply, State#state.election_epoch, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {noreply, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

%% TODO: how to restore state when consensus group changes
%% presumably if there's a crash and the consensus members changed, this becomes pointless
%% handle_info(maybe_restore_consensus, State=#state{election_interval=Interval}) ->
%%     Chain = blockchain_worker:blockchain(),
%%     case Chain of
%%         undefined ->
%%             {noreply, State};
%%         Chain ->
%%             {ok, Height} = blockchain:height(Chain),
%%             case Height rem Interval == 0 andalso Height /= 0 of
%%                 true ->
%%                     %% Restore an election round
%%                     {ok, Hash} = blockchain:head_hash(Chain),
%%                     {noreply, initiate_election(Chain, Hash, Height, State)};
%%                 false ->
%%                     Ledger = blockchain:ledger(Chain),
%%                     case blockchain_ledger_v1:consensus_members(Ledger) of
%%                         {error, _} ->
%%                             {noreply, State#state{blockchain=Chain}};
%%                         {ok, ConsensusAddrs} ->
%%                             case lists:member(blockchain_swarm:pubkey_bin(), ConsensusAddrs) of
%%                                 true ->
%%                                     lager:info("restoring consensus group"),
%%                                     Pos = miner_util:index_of(blockchain_swarm:pubkey_bin(), ConsensusAddrs),
%%                                     N = length(ConsensusAddrs),
%%                                     F = (N div 3),
%%                                     GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
%%                                                                       Pos,
%%                                                                       N,
%%                                                                       F,
%%                                                                       State#state.batch_size,
%%                                                                       undefined,
%%                                                                       Chain]],
%%                                     Ref = set_next_block_timer(Chain, State#state.block_time),
%%                                     Name = "consensus_" ++ integer_to_list(max(0, Height + 1 - (Height rem Interval))),
%%                                     lager:info("Restoring consensus group ~s", [Name]),
%%                                     {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), Name, libp2p_group_relcast, GroupArg),
%%                                     lager:info("~p. Group: ~p~n", [self(), Group]),
%%                                     ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
%%                                                                          {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
%%                                     {noreply, State#state{consensus_group=Group, block_timer=Ref, consensus_pos=Pos, blockchain=Chain}};
%%                                 false ->
%%                                     {noreply, State#state{blockchain=Chain}}
%%                             end
%%                     end
%%             end
%%     end;
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
                        Round = blockchain_block:hbbft_round(Block) + 1,
                        Txns = blockchain_block:transactions(Block),
                        case has_new_group(Txns) of
                            %% not here yet, regular round
                            false ->
                                case Height > (Start + Interval) of
                                    true when Waiting == undefined ->
                                        miner_election_mgr:start_election(Hash, Height);
                                    _ -> ok
                                end,
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
                                Buf = get_buf(ConsensusGroup),
                                set_buf(Waiting, Buf),

                                NextRound = Round + 1,
                                libp2p_group_relcast:handle_input(
                                  Waiting, {next_round, NextRound,
                                            blockchain_block:transactions(Block),
                                            Sync}),
                                catch libp2p_group_relcast:handle_command(ConsensusGroup, stop),
                                lager:info("got here"),
                                State#state{block_timer = set_next_block_timer(Chain, BlockTime),
                                            handoff_waiting = undefined,
                                            consensus_group = Waiting,
                                            election_epoch = State#state.election_epoch + 1,
                                            current_height = Height,
                                            consensus_start = Height};
                            %% we're not a member of the new group, we can shut down
                            {true, false} ->
                                libp2p_group_relcast:handle_command(ConsensusGroup, stop),

                                State#state{block_timer = undefined,
                                            handoff_waiting = undefined,
                                            consensus_group = undefined,
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
    {noreply, signal_syncing_status(Sync, NewState)};
handle_info({blockchain_event, {add_block, Hash, Sync}},
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         consensus_start = Start,
                         handoff_waiting = Waiting,
                         blockchain = Chain}) when ConsensusGroup == undefined andalso
                                                   Chain /= undefined ->
    lager:info("non-consensus block"),
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            case blockchain_block:height(Block) of
                Height when Height > CurrHeight ->
                    lager:info("nc processing block for ~p", [Height]),
                    case Height > (Start + Interval) of
                        true when Waiting == undefined ->
                            miner_election_mgr:start_election(Hash, Height);
                        _ -> ok
                    end,
                    {noreply, signal_syncing_status(Sync, State)};
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

get_buf(ConsensusGroup) ->
    case ConsensusGroup of
        P when is_pid(P) ->
            case is_process_alive(P) of
                true ->
                    case catch libp2p_group_relcast:handle_command(P, get_buf) of
                        {ok, B} ->
                            B;
                        _ ->
                            S = libp2p_group_relcast_sup:server(P),
                            lager:info("what the hell ~p", [erlang:process_info(S, current_stacktrace)]),
                            lager:info("what the hell ~p", [sys:get_state(S)]),
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
        %% I suspect that this doesn't properly handle the case where two of these get into a
        %% single transaction, but hopefully that isn't possible and would likely be a chain
        %% fork anyway?
        _ ->
            false
    end.
