%%%-------------------------------------------------------------------

%% @doc miner
%% @end
%%%-------------------------------------------------------------------
-module(miner).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/0,
    p2p_status/0,
    block_age/0,
    relcast_info/1,
    relcast_queue/1,
    hbbft_status/0,
    hbbft_skip/0,
    create_block/3,
    signed_block/2,

    start_chain/2,
    install_consensus/1,
    remove_consensus/0,
    version/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(state, {
    %% NOTE: a miner may or may not participate in consensus
    consensus_group :: undefined | pid(),
    blockchain :: undefined | blockchain:blockchain(),
    %% but every miner keeps a timer reference?
    block_timer = make_ref() :: reference(),
    current_height = -1 :: integer(),
    blockchain_ref = make_ref() :: reference()
}).

-define(H3_MINIMUM_RESOLUTION, 9).

-ifdef(TEST).

-define(tv, '$test_version').

-export([test_version/0, inc_tv/1]).

test_version() ->
    case ets:info(?tv) of
        undefined ->
            ets:new(?tv, [named_table, public]),
            ets:insert(?tv, {?tv, 1}),
            1;
        _ ->
            [{_, V}] = ets:lookup(?tv, ?tv),
            lager:info("tv got ~p", [V]),
            V
    end.

inc_tv(Incr) ->
    lager:info("increment: ~p", [Incr]),
    case ets:info(?tv) of
        undefined ->
            ets:new(?tv, [named_table, public]),
            ets:insert(?tv, {?tv, 1 + Incr}),
            1 + Incr;
        _ ->
            ets:update_counter(?tv, ?tv, Incr)
    end.

-endif.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], [{hibernate_after, 5000}]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
block_age() ->
    Chain = blockchain_worker:blockchain(),
    {ok, Block} = blockchain:head_block(Chain),
    erlang:system_time(seconds) - blockchain_block:time(Block).


%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec p2p_status() -> [{Check::string(), Result::string()}].
p2p_status() ->
    SwarmTID = blockchain_swarm:tid(),
    CheckSessions = fun() ->
                            case (catch length(libp2p_swarm:sessions(SwarmTID)) > 5) of
                                true -> "yes";
                                _  -> "no"
                            end
                    end,
    CheckPublicAddr = fun() ->
                              case (catch lists:any(fun(Addr) ->
                                                            libp2p_relay:is_p2p_circuit(Addr) orelse
                                                                libp2p_transport_tcp:is_public(Addr)
                                                    end, libp2p_swarm:listen_addrs(SwarmTID))) of
                                  true -> "yes";
                                  _ -> "no"
                              end
                      end,
    CheckNatType = fun() ->
                           try
                               case libp2p_peerbook:get(libp2p_swarm:peerbook(SwarmTID),
                                                        libp2p_swarm:pubkey_bin(SwarmTID)) of
                                   {ok, Peer} -> atom_to_list(libp2p_peer:nat_type(Peer));
                                   {error, _} -> "unknown"
                               end
                           catch _:_ ->
                                   "unknown"
                           end
                   end,
    CheckHeight = fun() ->
                          Chain = blockchain_worker:blockchain(),
                          {ok, Height} = blockchain:height(Chain),
                          integer_to_list(Height)
                  end,
    lists:foldr(fun({Fun, Name}, Acc) ->
                        [{Name, Fun()} | Acc]
                end, [], [{CheckSessions, "connected"},
                          {CheckPublicAddr, "dialable"},
                          {CheckNatType, "nat_type"},
                          {CheckHeight, "height"}]).

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
-spec create_block(Metadata :: [{pos_integer(), #{}},...],
                   Txns :: blockchain_txn:txns(),
                   HBBFTRound :: non_neg_integer())
                  -> {ok,
                      Address :: libp2p_crypto:pubkey_bin(),
                      UsignedBinaryBlock :: binary(),
                      Signature :: binary(),
                      PendingTxns :: blockchain_txn:txns(),
                      InvalidTxns :: blockchain_txn:txns()} |
                     {error, term()}.
create_block(Metadata, Txns, HBBFTRound) ->
    try
        gen_server:call(?MODULE, {create_block, Metadata, Txns, HBBFTRound}, infinity)
    catch exit:{noproc, _} ->
            %% if the miner noprocs, we're likely shutting down
            {error, no_miner}
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
                    miner ! block_timeout,
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
            SwarmTID = blockchain_swarm:tid(),
            libp2p_group_gossip:send(
              libp2p_swarm:gossip_group(SwarmTID),
              ?GOSSIP_PROTOCOL_V1,
              blockchain_gossip_handler:gossip_data(SwarmTID, Block)
             ),
            {Signatories, _} = lists:unzip(blockchain_block:signatures(Block)),

            {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(blockchain:ledger(Chain)),
            %% FF non signatory consensus members
            lists:foreach(
              fun(Member) ->
                      spawn(fun() -> blockchain_fastforward_handler:dial(Swarm, Chain, libp2p_crypto:pubkey_bin_to_p2p(Member)) end)
              end, ConsensusAddrs -- Signatories);

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

install_consensus(ConsensusGroup) ->
    gen_server:cast(?MODULE, {install_consensus, ConsensusGroup}).

remove_consensus() ->
    gen_server:cast(?MODULE, remove_consensus).

-spec version() -> integer().
version() ->
    2.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------


init(_Args) ->
    lager:info("STARTING UP MINER"),
    ok = blockchain_event:add_handler(self()),
    BlockchainRef = erlang:monitor(process, blockchain_worker),
    case blockchain_worker:blockchain() of
        undefined ->
            {ok, #state{}};
        Chain ->
            {ok, #state{blockchain = Chain,
                        blockchain_ref = BlockchainRef}}
    end.

handle_call(consensus_group, _From, State) ->
    {reply, State#state.consensus_group, State};
handle_call({start_chain, ConsensusGroup, Chain}, _From, State) ->
    lager:info("registering first consensus group"),
    {reply, ok, set_next_block_timer(State#state{consensus_group = ConsensusGroup,
                                                 blockchain = Chain})};
handle_call({create_block, Metadata, Txns, HBBFTRound}, _From, State) ->
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    Chain = blockchain_worker:blockchain(),
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    CurrentBlockHeight = blockchain_block:height(CurrentBlock),
    NewHeight = CurrentBlockHeight + 1,
    {ElectionEpoch0, EpochStart0} = blockchain_block_v1:election_info(CurrentBlock),
    lager:debug("Metadata ~p, current hash ~p", [Metadata, CurrentBlockHash]),
    %% we expect every stamp to contain the same block hash
    StampHashes =
        lists:foldl(fun({_, {Stamp, Hash}}, Acc) -> % old tuple vsn
                            [{Stamp, Hash} | Acc];
                       ({_, #{head_hash := Hash, timestamp := Stamp}}, Acc) -> % new map vsn
                            [{Stamp, Hash} | Acc];
                       (_, Acc) ->
                            %% maybe crash here?
                            Acc
                    end,
                    [],
                    Metadata),
    SeenBBAs =
        lists:foldl(fun({Idx, #{seen := Seen, bba_completion := B}}, Acc) -> % new map vsn
                            [{{Idx, Seen}, B} | Acc];
                       (_, Acc) ->
                            %% maybe crash here?
                            Acc
                    end,
                    [],
                    Metadata),
    Ledger = blockchain:ledger(Chain),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),
    F = ((N - 1) div 3),

    %% find a snapshot hash.  if not enabled or we're unable to determine or agree on one, just
    %% leave it blank, so other nodes can absorb it.
    SnapshotHash =
        case blockchain:config(?snapshot_interval, Ledger) of
            {ok, Interval} ->
                %% if we're expecting a snapshot
                case (NewHeight - 1) rem Interval == 0 of
                    true ->
                        %% iterate through the metadata collecting them
                        SHCt =
                            lists:foldl(
                              %% we have one, so count unique instances of it
                              fun({_Idx, #{snapshot_hash := SH}}, Acc) ->
                                      maps:update_with(SH, fun(V) -> V + 1 end, 1, Acc);
                                 (_, Acc) ->
                                      Acc
                              end,
                              #{},
                              Metadata),
                        %% flatten the map into a list, sorted by hash count, highest first. take
                        %% the most common one and make sure that enough nodes agree on that
                        %% snapshot. if not, don't return anything.
                        case lists:reverse(lists:keysort(2, maps:to_list(SHCt))) of
                            [] -> <<>>;
                            %% head should be the node with the highest count.  don't include it if
                            %% we have too much disagreement or not enough reports
                            [{_, Ct} | _ ] when Ct < ((2*F)+1) -> <<>>;
                            [{SH, _Ct} | _ ] -> SH
                        end;
                    _ -> <<>>
                end;
            _ -> <<>>
        end,
    {Stamps, Hashes} = lists:unzip(StampHashes),
    {SeenVectors, BBAs} = lists:unzip(SeenBBAs),
    {ok, Consensus} = blockchain_ledger_v1:consensus_members(blockchain:ledger(State#state.blockchain)),
    BBA = process_bbas(length(Consensus), BBAs),
    Reply =
        case lists:usort(Hashes) of
            [CurrentBlockHash] ->
                SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Txns),
                lager:info("metadata snapshot hash for ~p is ~p", [NewHeight, SnapshotHash]),
                %% populate this from the last block, unless the last block was the genesis
                %% block in which case it will be 0
                LastBlockTime = blockchain_block:time(CurrentBlock),
                BlockTime =
                    case miner_util:median([ X || X <- Stamps,
                                                  X >= LastBlockTime]) of
                        0 ->
                            LastBlockTime + 1;
                        LastBlockTime ->
                            LastBlockTime + 1;
                        NewTime ->
                            NewTime
                    end,
                {ValidTransactions, InvalidTransactions} = blockchain_txn:validate(SortedTransactions, Chain),

                {ElectionEpoch, EpochStart, TxnsToInsert} =
                    case blockchain_election:has_new_group(ValidTransactions) of
                        {true, _, ConsensusGroupTxn, _} ->
                            Epoch = ElectionEpoch0 + 1,
                            Start = EpochStart0 + 1,
                            End = CurrentBlockHeight,
                            {ok, Rewards} = blockchain_txn_rewards_v1:calculate_rewards(Start, End, Chain),
                            lager:debug("Rewards: ~p~n", [Rewards]),
                            RewardsTxn = blockchain_txn_rewards_v1:new(Start, End, Rewards),
                            %% to cut down on the size of group txn blocks, which we'll
                            %% need to fetch and store all of to validate snapshots, we
                            %% discard all other txns for this block
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
                               epoch_start => EpochStart,
                               seen_votes => SeenVectors,
                               bba_completion => BBA,
                               snapshot_hash => SnapshotHash
                              }),
                {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
                BinNewBlock = blockchain_block:serialize(NewBlock),
                Signature = SignFun(BinNewBlock),
                %% XXX: can we lose state here if we crash and recover later?
                lager:debug("Worker:~p, Created Block: ~p, Txns: ~p",
                            [self(), NewBlock, TxnsToInsert]),
                %% return both valid and invalid transactions to be deleted from the buffer
                {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock,
                 Signature, TxnsToInsert, InvalidTransactions};
            [_OtherBlockHash] ->
                {error, stale_hash};
            List ->
                lager:warning("got unexpected block hashes in stamp information ~p", [List]),
                {error, multiple_hashes}
        end,
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_cast(remove_consensus, State) ->
    erlang:cancel_timer(State#state.block_timer),
    {noreply, State#state{consensus_group = undefined,
                          block_timer = make_ref()}};
handle_cast({install_consensus, NewConsensusGroup},
            #state{consensus_group = Group} = State) when Group == NewConsensusGroup ->
    {noreply, State};
handle_cast({install_consensus, NewConsensusGroup},
            State) ->
    lager:info("installing consensus ~p after ~p",
               [NewConsensusGroup, State#state.consensus_group]),
    {noreply, set_next_block_timer(State#state{consensus_group = NewConsensusGroup})};
handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, Reason}, State = #state{blockchain_ref=Ref}) ->
    lager:warning("Blockchain worker exited with reason ~p", [Reason]),
    {stop, Reason, State};
handle_info(block_timeout, State) when State#state.consensus_group == undefined ->
    {noreply, State};
handle_info(block_timeout, State) ->
    lager:info("block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    {noreply, State};
handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            State=#state{consensus_group = ConsensusGroup,
                         current_height = CurrHeight,
                         blockchain = Chain}) when ConsensusGroup /= undefined andalso
                                                   Chain /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
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
                            false ->
                                lager:debug("reg round c ~p", [Height]),
                                NextRound = Round + 1,
                                libp2p_group_relcast:handle_input(
                                  ConsensusGroup, {next_round, NextRound,
                                                   blockchain_block:transactions(Block),
                                                   Sync}),
                                set_next_block_timer(State#state{current_height = Height});

                            {true, _, _, _} ->
                                State#state{block_timer = make_ref(),
                                            current_height = Height}
                        end;
                    _Height ->
                        lager:debug("skipped re-processing block for ~p", [_Height]),
                        State
                end;
            {error, Reason} ->
                lager:error("Error, Reason: ~p", [Reason]),
                State
        end,
    {noreply, NewState};
handle_info({blockchain_event, {add_block, Hash, _Sync, _Ledger}},
            #state{consensus_group = ConsensusGroup,
                   current_height = CurrHeight,
                   blockchain = Chain} = State) when ConsensusGroup == undefined andalso
                                                     Chain /= undefined ->
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            Height = blockchain_block:height(Block),
            lager:info("non-consensus block ~p", [Height]),
            case Height of
                H when H > CurrHeight ->
                    {noreply, State#state{current_height = Height}};
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
    {noreply, State#state{blockchain = Chain}};
handle_info({blockchain_event, {new_chain, NC}}, #state{blockchain_ref = Ref}) ->
    State1 = #state{blockchain = NC,
                    blockchain_ref = Ref},
    {noreply, State1};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("stopping: ~p", [Reason]),
    ok.

%% ==================================================================
%% Internal functions
%% =================================================================

set_next_block_timer(State=#state{blockchain=Chain}) ->
    Now = erlang:system_time(seconds),
    {ok, BlockTime0} = blockchain:config(?block_time, blockchain:ledger(Chain)),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    BlockTime = BlockTime0 div 1000,
    {ok, Height} = blockchain:height(Chain),
    LastBlockTimestamp = case Height of
                             1 ->
                                 %% make up a plausible time for the genesis block
                                 Now;
                             _ ->
                                 blockchain_block:time(HeadBlock)
                         end,

    StartHeight0 = application:get_env(miner, stabilization_period, 0),
    StartHeight = max(1, Height - StartHeight0),
    {ActualStartHeight, StartBlockTime} =
        case Height > StartHeight of
            true ->
                case blockchain:find_first_block_after(StartHeight, Chain) of
                    {ok, Actual, StartBlock} ->
                        {Actual, blockchain_block:time(StartBlock)};
                    _ ->
                        {0, undefined}
                end;
            false ->
                {0, undefined}
        end,
    AvgBlockTime = case StartBlockTime of
                       undefined ->
                           BlockTime;
                       _ ->
                           (LastBlockTimestamp - StartBlockTime) / (Height - ActualStartHeight)
                   end,
    BlockTimeDeviation0 = BlockTime - AvgBlockTime,
    lager:info("average ~p block times ~p difference ~p", [Height, AvgBlockTime, BlockTime - AvgBlockTime]),
    BlockTimeDeviation =
        case BlockTimeDeviation0 of
            N when N > 0 ->
                min(ceil(N * N), 15);
            N ->
                %% to maintain sensitivity, and actually cap slowdown,
                %% invert all the operations here, and use abs to
                %% preserve sign.
                max(floor(N * abs(N)), -15)
        end,
    NextBlockTime = max(0, (LastBlockTimestamp + BlockTime + BlockTimeDeviation) - Now),
    lager:info("Next block after ~p is in ~p seconds", [LastBlockTimestamp, NextBlockTime]),
    Timer = erlang:send_after(NextBlockTime * 1000, self(), block_timeout),
    State#state{block_timer=Timer}.

process_bbas(N, BBAs) ->
    %% 2f + 1 = N - ((N - 1) div 3)
    Threshold = N - ((N - 1) div 3),
    M = lists:foldl(fun(B, Acc) -> maps:update_with(B, fun(V) -> V + 1 end, 1, Acc) end, #{}, BBAs),
    case maps:size(M) of
        0 ->
            <<>>;
        _ ->
            %% this should work for any other value
            [{BBAVal, Ct} | _] = lists:reverse(lists:keysort(2, maps:to_list(M))),
            case Ct >= Threshold of
                true ->
                    BBAVal;
                _ ->
                    <<>>
            end
    end.
