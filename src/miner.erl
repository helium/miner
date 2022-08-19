-module(miner).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

%% API
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

    keys/0,

    reset_late_block_timer/0,
    calculate_next_block_time/1, calculate_next_block_time/2,

    start_chain/2,
    install_consensus/1,
    group_block_time/1,
    remove_consensus/0,
    version/0
]).

-export_type([
    create_block_ok/0,
    create_block_error/0,
    create_block_result/0
]).

%% gen_server
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).


-type metadata_v1() ::
    {integer(), blockchain_block:hash()}.

-type metadata_v2() ::
    #{
        timestamp      => integer(),
        seen           => binary(),
        bba_completion => binary(),
        head_hash      => blockchain_block:hash(),
        snapshot_hash  => binary()
     }.

-type metadata_v3() ::
    #{
        timestamp           => integer(),
        seen                => binary(),
        bba_completion      => binary(),
        head_hash           => blockchain_block:hash(),
        snapshot_hash       => binary(),
        target_block_time   => integer()
     }.

-type metadata() ::
    [{J :: pos_integer(), M :: metadata_v3() | metadata_v2() | metadata_v1()}].

-type swarm_keys() ::
    {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun()}.

-type create_block_error() ::
      stale_hash
    | multiple_hashes.

-type create_block_ok() ::
    #{
        address               =>  libp2p_crypto:pubkey_bin(),
        unsigned_binary_block =>  binary(),
        signature             =>  binary(),
        pending_txns          =>  blockchain_txn:txns(),
        invalid_txns          =>  blockchain_txn:txns()
    }.

-type create_block_result() ::
      {ok, create_block_ok()}
    | {error, create_block_error()}.

-record(state, {
    %% NOTE: a miner may or may not participate in consensus
    consensus_group :: undefined | pid(),
    blockchain :: undefined | blockchain:blockchain(),
    %% but every miner keeps a timer reference?
    block_timer = make_ref() :: reference(),
    target_block_time :: undefined | integer(),
    late_block_timer = make_ref() :: reference(),
    current_height = -1 :: integer(),
    blockchain_ref = make_ref() :: reference(),
    swarm_tid :: ets:tid() | atom(),
    swarm_keys :: swarm_keys()
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

%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], [{hibernate_after, 5000}]).

block_age() ->
    Chain = blockchain_worker:blockchain(),
    {ok, #block_info_v2{time=BlockTime}} = blockchain:head_block_info(Chain),
    erlang:system_time(seconds) - BlockTime.

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
        Pid -> libp2p_group_relcast:info(Pid)
    end.

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

-spec create_block(metadata(), blockchain_txn:txns(), non_neg_integer()) ->
    create_block_result().
create_block(Metadata, Txns, HBBFTRound) ->
    try
        gen_server:call(?MODULE, {create_block, Metadata, Txns, HBBFTRound}, infinity)
    catch exit:{noproc, _} ->
            %% if the miner noprocs, we're likely shutting down
            {error, no_miner}
    end.

-spec hbbft_status() -> map() | {error, timeout}.
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

-spec hbbft_skip() -> ok | {error, timeout}.
hbbft_skip() ->
    case gen_server:call(?MODULE, consensus_group, 60000) of
        undefined -> ok;
        Pid ->
            ok = libp2p_group_relcast:handle_input(Pid, maybe_skip)
    end.

-spec signed_block([binary()], binary()) -> ok.
signed_block(Signatures, BinBlock) ->
    %% Once a miner gets a sign_block message (only happens if the miner is in
    %% consensus group):
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
            Data =
                case application:get_env(blockchain, gossip_version, 1) of
                    1 ->
                        blockchain_gossip_handler:gossip_data_v1(SwarmTID, Block);
                    2 ->
                        Height = blockchain_block:height(Block),
                        {ok, #block_info_v2{hash = Hash}} = blockchain:get_block_info(Height, Chain),
                        blockchain_gossip_handler:gossip_data_v2(SwarmTID, Hash, Height)
                end,

            libp2p_group_gossip:send(
              SwarmTID,
              ?GOSSIP_PROTOCOL_V1,
              Data
             ),
            {Signatories, _} = lists:unzip(blockchain_block:signatures(Block)),

            {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(blockchain:ledger(Chain)),
            %% FF non signatory consensus members
            lists:foreach(
              fun(Member) ->
                      spawn(fun() ->
                                    blockchain_fastforward_handler:dial(
                                      Swarm,
                                      Chain,
                                      libp2p_crypto:pubkey_bin_to_p2p(Member))
                            end)
              end, ConsensusAddrs -- Signatories);

        Error ->
            lager:error("signed_block, error: ~p", [Error])
    end,
    ok.

-spec keys() -> {ok, {libp2p_crypto:pubkey(), libp2p_crypto:sig_fun()}}.
keys() ->
    gen_server:call(?MODULE, keys).

-spec reset_late_block_timer() -> ok.
reset_late_block_timer() ->
    gen_server:call(?MODULE, reset_late_block_timer).

start_chain(ConsensusGroup, Chain) ->
    gen_server:call(?MODULE, {start_chain, ConsensusGroup, Chain}, infinity).

install_consensus(ConsensusGroup) ->
    gen_server:cast(?MODULE, {install_consensus, ConsensusGroup}).

-spec group_block_time(integer()) -> ok.
group_block_time(GroupBlockTime) ->
    gen_server:cast(?MODULE, {group_block_time, GroupBlockTime}).

remove_consensus() ->
    gen_server:cast(?MODULE, remove_consensus).


-spec version() -> integer().
version() ->
    %% format:
    %% MMMmmmPPPP
       0010140000.

%% ------------------------------------------------------------------
%% gen_server
%% ------------------------------------------------------------------

init(_Args) ->
    Mode = application:get_env(miner, mode),
    lager:info("STARTING UP MINER with mode ~p", [Mode]),
    ok = blockchain_event:add_handler(self()),
    %% TODO: Maybe put this somewhere else?
    ok = miner_discovery_handler:add_stream_handler(blockchain_swarm:tid()),
    BlockchainRef = erlang:monitor(process, blockchain_worker),
    {ok, MyPubKey, SignFun, _ECDHFun} = blockchain_swarm:keys(),
    SwarmTID = blockchain_swarm:tid(), % We don't actually use this for
                                       % anything at this time, but we should
                                       % use this if we need it.
    case blockchain_worker:blockchain() of
        undefined ->
            {ok, #state{swarm_keys = {MyPubKey, SignFun},
                        swarm_tid = SwarmTID}};
        Chain ->
            {ok, #state{swarm_keys = {MyPubKey, SignFun},
                        swarm_tid = SwarmTID,
                        blockchain = Chain,
                        blockchain_ref = BlockchainRef}}
    end.

handle_call(consensus_group, _From, State) ->
    {reply, State#state.consensus_group, State};
handle_call({start_chain, ConsensusGroup, Chain}, _From, State) ->
    lager:info("registering first consensus group"),
    {reply, ok, set_next_block_timer(State#state{consensus_group = ConsensusGroup,
                                                 blockchain = Chain})};
handle_call({create_block, Metadata, Txns, HBBFTRound}, _From,
            #state{blockchain = Chain, swarm_keys = SK} = State) ->
    Result = try_create_block(Metadata, Txns, HBBFTRound, Chain, SK),
    {reply, Result, State};
handle_call(keys, _From, State) ->
    {reply, {ok, State#state.swarm_keys}, State};
handle_call(reset_late_block_timer, _From, State) ->
    erlang:cancel_timer(State#state.late_block_timer),
    LateBlockTimeout = application:get_env(miner, late_block_timeout_seconds, 120),
    LateTimer = erlang:send_after(LateBlockTimeout * 1000, self(), late_block_timeout),

    {reply, ok, State#state{late_block_timer = LateTimer}};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_cast(remove_consensus, State) ->
    erlang:cancel_timer(State#state.block_timer),
    {noreply, State#state{consensus_group = undefined,
                          block_timer = make_ref(),
                          target_block_time = undefined}};
handle_cast({install_consensus, NewConsensusGroup},
            #state{consensus_group = Group} = State) when Group == NewConsensusGroup ->
    {noreply, State};
handle_cast({install_consensus, NewConsensusGroup},
            State) ->
    lager:info("installing consensus ~p after ~p",
               [NewConsensusGroup, State#state.consensus_group]),
    {noreply, set_next_block_timer(State#state{consensus_group = NewConsensusGroup})};
handle_cast({group_block_time, GroupBlockTime},
            #state{target_block_time=TargetBlockTime} = State) ->
    Now = erlang:system_time(seconds),
    %% the group block time is the next subsequent block time due to BBA
    %% therefore, the GroupBlockTime should always be >= the current
    %% TargetBlockTime
    case Now >= GroupBlockTime orelse TargetBlockTime >= GroupBlockTime of
        true ->
            lager:info("Invalid target block time from group, tried ~p when already set at ~p", [GroupBlockTime, TargetBlockTime]),
            {noreply, State#state{target_block_time = undefined}};
        false ->
            lager:info("Setting target block timeout to ~p from group", [GroupBlockTime]),
            {noreply, State#state{target_block_time = GroupBlockTime}}
    end;
handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, Reason}, State = #state{blockchain_ref=Ref}) ->
    lager:warning("Blockchain worker exited with reason ~p", [Reason]),
    {stop, Reason, State};
handle_info(block_timeout, State) when State#state.consensus_group == undefined ->
    {noreply, State#state{target_block_time=undefined}};
handle_info(block_timeout, #state{target_block_time=TargetBlockTime} = State) ->
    Now = erlang:system_time(seconds),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    case Now >= TargetBlockTime of
        true ->
            lager:info("block timeout at ~p", [Now]),
            {noreply, set_next_block_timer(State#state{target_block_time=undefined})};
        false ->
            %% target block time came from group keep it to set next block timer
            lager:info("block timeout at ~p, next set in ~ps", [Now, TargetBlockTime - Now]),
            {noreply, set_next_block_timer(State)}
    end;
handle_info(late_block_timeout, State) ->
    LateBlockTimeout = application:get_env(miner, late_block_timeout_seconds, 120) * 1000,
    lager:info("late block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, maybe_skip),
    LateTimer = erlang:send_after(LateBlockTimeout, self(), late_block_timeout),
    {noreply, State#state{late_block_timer=LateTimer, target_block_time=undefined}};
handle_info({blockchain_event, {add_block, Hash, Sync, Ledger}},
            State=#state{consensus_group = ConsensusGroup,
                         current_height = CurrHeight,
                         swarm_keys = {PubKey, _SigFun},
                         blockchain = Chain}) when ConsensusGroup /= undefined andalso
                                                   Chain /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft
    %% round, make it forcefully go to next round
    NewState =
        case blockchain:get_block_height(Hash, Chain) of
            {ok, Height} when Height > CurrHeight ->
                case blockchain:get_block(Hash, Chain) of
                    {ok, Block} ->
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
                                                   Txns, Sync}),
                                {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
                                F = (length(ConsensusAddrs) - 1) div 3,
                                BBAs = blockchain_utils:bitvector_to_map(length(ConsensusAddrs), blockchain_block_v1:bba_completion(Block)),
                                BBAAddrs = maps:fold(fun(K, true, Acc) ->
                                                             [lists:nth(K, ConsensusAddrs) | Acc];
                                                        (_, _, Acc) ->
                                                             Acc
                                                     end, [], BBAs),
                                case lists:member(libp2p_crypto:pubkey_to_bin(PubKey), BBAAddrs) orelse length(BBAAddrs) < (2 * F)+1 of
                                    true ->
                                        %% we got our proposal in last round, or we didn't see enough BBA votes
                                        %% to know if we did
                                        set_next_block_timer(State#state{current_height = Height});
                                    false ->
                                        lager:info("jumping to next hbbft round ~p early", [Round+1]),
                                        %% didn't get included last round, try to get a jump on things
                                        Timer = erlang:send_after(0, self(), block_timeout),
                                        %% now figure out the late block timer
                                        erlang:cancel_timer(State#state.late_block_timer),
                                        LateBlockTimeout = application:get_env(miner, late_block_timeout_seconds, 120),
                                        LateTimer = erlang:send_after(LateBlockTimeout * 1000, self(), late_block_timeout),
                                        State#state{block_timer=Timer, late_block_timer=LateTimer}
                                end;
                            {true, _, _, _} ->
                                State#state{block_timer = make_ref(),
                                            current_height = Height,
                                            target_block_time = undefined}
                        end;
                    {error, Reason} ->
                        lager:error("Error, Reason: ~p", [Reason]),
                        State
                end;
            {ok, _Height} ->
                        lager:debug("skipped re-processing block for ~p", [_Height]),
                        State
        end,
    {noreply, NewState};
handle_info({blockchain_event, {add_block, Hash, _Sync, _Ledger}},
            #state{consensus_group = ConsensusGroup,
                   current_height = CurrHeight,
                   blockchain = Chain} = State) when ConsensusGroup == undefined andalso
                                                     Chain /= undefined ->
    case blockchain:get_block_height(Hash, Chain) of
        {ok, Height} ->
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
handle_info({blockchain_event, {new_chain, NC}}, #state{blockchain_ref = Ref, swarm_keys=SK, swarm_tid=STid}) ->
    State1 = #state{blockchain = NC,
                    blockchain_ref = Ref,
                    swarm_keys=SK,
                    swarm_tid=STid},
    {noreply, State1};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:info("stopping: ~p", [Reason]),
    ok.

%% ============================================================================
%% Private
%% ============================================================================

-spec try_create_block(
    metadata(),
    blockchain_txn:txns(),
    non_neg_integer(),
    blockchain:blockchain(),
    swarm_keys()
) ->
    create_block_result().
try_create_block(Metadata, Txns, HBBFTRound, Chain, SwarmKeys) ->
    %% This can actually be a stale message, in which case we'd produce a block
    %% with a garbage timestamp. This is not actually that big of a deal, since
    %% it won't be accepted, but we can short circuit some effort by checking
    %% for a stale hash.
    {ok, HashCurr} = blockchain:head_hash(Chain),
    lager:debug("Metadata ~p, current hash ~p", [Metadata, HashCurr]),
    N = count_consensus_members(Chain),
    VotesNeeded = N - ((N - 1) div 3),
    {_, Hashes} = meta_to_stamp_hashes(Metadata),
    case hash_check_if_stale(HashCurr, Hashes, VotesNeeded) of
        {ok, {}} ->
            {ok, create_block(Metadata, Txns, HBBFTRound, Chain, VotesNeeded, SwarmKeys)};
        {error, {stale, HashStale, Votes}} ->
            lager:warning("Stale hash: ~p, picked by ~b nodes.", [HashStale, Votes]),
            {error, stale_hash};
        {error, {unexpected_counts, Counts}} ->
            lager:warning(
                "got unexpected block hashes in stamp information ~p",
                [Counts]
            ),
            %% XXX May also be [], so not just multiple!
            {error, multiple_hashes}
    end.

-spec count_consensus_members(blockchain:blockchain()) -> non_neg_integer().
count_consensus_members(Chain) ->
    {ok, ConsensusMembers} =
        blockchain_ledger_v1:consensus_members(blockchain:ledger(Chain)),
    length(ConsensusMembers).

-spec hash_check_if_stale(H, [H], C) -> {ok, {}} | {error, E} when
    E ::  {stale, H, C}
        | {unexpected_counts, [{H, C}]},
    H :: blockchain_block:hash(),
    C :: non_neg_integer().
hash_check_if_stale(HashCurr, Hashes, VotesNeeded) ->
    case
        lists:filter(
            fun ({_, Votes}) -> Votes >= VotesNeeded end,
            maps:to_list(miner_util:list_count(Hashes))
        )
    of
        %% We expect every stamp to contain the same block hash:
        [{HashCurr, _}]      -> {ok, {}};
        [{HashStale, Votes}] -> {error, {stale, HashStale, Votes}};
        Counts               -> {error, {unexpected_counts, Counts}}
    end.

-spec create_block(
    metadata(),
    blockchain_txn:txns(),
    non_neg_integer(),
    blockchain:blockchain(),
    non_neg_integer(),
    swarm_keys()
) ->
    create_block_ok().
create_block(Metadata, Txns, HBBFTRound, Chain, VotesNeeded, {MyPubKey, SignFun}) ->
    {ok, #block_info_v2{height=HeightCurr, time=CurrentBlockTime, hash=CurrentBlockHash, election_info=ElectionInfo}} = blockchain:head_block_info(Chain),
    HeightNext = HeightCurr + 1,
    Ledger = blockchain:ledger(Chain),
    SnapshotHash = snapshot_hash(Ledger, HeightNext, Metadata, VotesNeeded),
    SeenBBAs =
        [{{J, S}, B} || {J, #{seen := S, bba_completion := B}} <- metadata_is_map(Metadata)],
    {SeenVectors, BBAs} = lists:unzip(SeenBBAs),
    %% if we cannot agree on the BBA results, default to flagging everyone as having completed
    VoteDefault =
        case blockchain:config(?election_version, Ledger) of
            {ok, N} when N >= 5 ->
                blockchain_utils:map_to_bitvector(
                  maps:from_list([ {I, true}
                                   || I <- lists:seq(1, count_consensus_members(Chain))]));
            _ -> <<>>
        end,

    BBA = common_enough_or_default(VotesNeeded, BBAs, VoteDefault),
    {ElectionEpoch, EpochStart, TxnsToInsert, InvalidTransactions} =
        select_transactions(Chain, Txns, ElectionInfo, HeightCurr, HeightNext),
    
    GroupBlockTimeout = median_time(CurrentBlockTime, Metadata, target_block_time),
    group_block_time(GroupBlockTimeout),
    
    NewBlock =
        blockchain_block_v1:new(#{
            prev_hash       =>  CurrentBlockHash,
            height          =>  HeightNext,
            transactions    =>  TxnsToInsert,
            signatures      =>  [],
            hbbft_round     =>  HBBFTRound,
            time            =>  median_time(CurrentBlockTime,  Metadata, timestamp),
            election_epoch  =>  ElectionEpoch,
            epoch_start     =>  EpochStart,
            seen_votes      =>  SeenVectors,
            bba_completion  =>  BBA,
            snapshot_hash   =>  SnapshotHash
        }),
    BinNewBlock = blockchain_block:serialize(NewBlock),
    Signature = SignFun(BinNewBlock),
    lager:debug("Worker:~p, Created Block: ~p, Txns: ~p",
                [self(), NewBlock, TxnsToInsert]),
    #{
        address               => libp2p_crypto:pubkey_to_bin(MyPubKey),
        unsigned_binary_block => BinNewBlock,
        signature             => Signature,

        %% Both pending and invalid are to be removed from the buffer:
        pending_txns          => TxnsToInsert,
        invalid_txns          => InvalidTransactions
    }.

%% TODO - Check if works with metadata_v1
-spec median_time(non_neg_integer(), metadata(), atom()) -> pos_integer().
median_time(LastBlockTime, Metadata, Key) ->
    %% Try to rule out invalid values by not allowing timestamps to go
    %% backwards and take the median proposed value.
    Times = meta_key_to_values(Metadata, Key),
    case miner_util:median([T || T <- Times, T >= LastBlockTime]) of
        0             -> LastBlockTime + 1;
        LastBlockTime -> LastBlockTime + 1;
        NewTime       -> NewTime
    end.

-spec select_transactions(
    blockchain:blockchain(),
    blockchain_txn:txns(),
    {non_neg_integer(), non_neg_integer()},
    non_neg_integer(),
    non_neg_integer()
) ->
    {
        ElectionEpoch :: non_neg_integer(),
        EpochStart :: non_neg_integer(),
        TxsValid   :: blockchain_txn:txns(),
        TxsInvalid :: blockchain_txn:txns()
    }.
select_transactions(Chain, Txns, {ElectionEpoch0, EpochStart0}, BlockHeightCurr, BlockHeightNext) ->
    SortedTransactions =
        lists:sort(fun blockchain_txn:sort/2, [T || T <- Txns, not txn_is_rewards(T)]),
    {ValidTransactions0, InvalidTransactions0} = blockchain_txn:validate(SortedTransactions, Chain),
    %% InvalidTransactions0 is a list of tuples in the format {Txn, InvalidReason}
    %% we dont need the invalid reason here so need to remove the tuple format
    %% and have a regular list of txn items in prep for returning to hbbft.
    InvalidTransactions1 = [InvTxn || {InvTxn, _InvalidReason} <- InvalidTransactions0],

    Ledger = blockchain:ledger(Chain),

    SizeLimit = case blockchain:config(?block_size_limit, Ledger) of
                    {ok, Limit} -> Limit;
                    _ -> 50*1024*1024 %% 50mb default
                end,
    {_, ValidTransactions1} = lists:foldl(fun(_Txn, {done, Acc}) ->
                                                 %% already full, don't want to skip because
                                                 %% of possible txn ordering issues so just drop everything
                                                 {done, Acc};
                                             (Txn, {Count, Acc}) ->
                                                 case Count - byte_size(blockchain_txn:serialize(Txn)) of
                                                     Remainder when Remainder < 0 ->
                                                         {done, Acc};
                                                     Remainder ->
                                                         {Remainder, [Txn|Acc]}
                                                 end
                                         end, {SizeLimit, []}, ValidTransactions0),

    ValidTransactions = lists:reverse(ValidTransactions1),

    %% any that overflowed go back into the buffer
    InvalidTransactions = InvalidTransactions1 ++ (ValidTransactions0 -- ValidTransactions),
    case blockchain_election:has_new_group(ValidTransactions) of
            {true, _, ConsensusGroupTxn, _} ->
                Epoch = ElectionEpoch0 + 1,
                Start = EpochStart0 + 1,
                End = BlockHeightCurr,
                RewardsMod =
                    case blockchain:config(?rewards_txn_version, Ledger) of
                         {ok, 2} -> blockchain_txn_rewards_v2;
                         _       -> blockchain_txn_rewards_v1
                     end,
                {ok, Rewards} = RewardsMod:calculate_rewards(Start, End, Chain),
                blockchain_hex:destroy_memoization(),
                lager:debug("RewardsMod: ~p, Rewards: ~p~n", [RewardsMod, Rewards]),
                RewardsTxn = RewardsMod:new(Start, End, Rewards),
                %% To cut down on the size of group txn blocks, which we'll
                %% need to fetch and store all of to validate snapshots, we
                %% discard all other txns for this block.
                Transactions =
                    lists:sort(
                        %% TODO Rename blockchain_txn:sort to blockchain_txn:(compare|cmp)
                        fun blockchain_txn:sort/2,
                        [RewardsTxn, ConsensusGroupTxn]
                     ),
                {Epoch, BlockHeightNext, Transactions, InvalidTransactions};
            _ ->
                {ElectionEpoch0, EpochStart0, ValidTransactions, InvalidTransactions}
        end.

-spec txn_is_rewards(blockchain_txn:txn()) -> boolean().
txn_is_rewards(Txn) ->
    Rewards = [blockchain_txn_rewards_v1, blockchain_txn_rewards_v2],
    lists:member(blockchain_txn:type(Txn), Rewards).

-spec metadata_is_map(metadata()) ->
    [{non_neg_integer(), metadata_v3() | metadata_v2()}].
metadata_is_map(Metadata) ->
    lists:filter(fun ({_, M}) -> is_map(M) end, Metadata).

-spec meta_key_to_values(metadata(), atom()) -> [any()].
meta_key_to_values(Metadata, Key) ->
    [Value || {_, #{Key := Value}} <- Metadata].

-spec meta_to_stamp_hashes(metadata()) ->
    {
        Stamps :: [integer()],
        Hashes :: [blockchain_block:hash()]
    }.
meta_to_stamp_hashes(Metadata) ->
    lists:unzip([metadata_as_v1(M) || {_, M} <- Metadata]).

-spec metadata_as_v1(metadata_v3() | metadata_v2() | metadata_v1()) -> metadata_v1().
metadata_as_v1(#{head_hash := H, timestamp := S}) -> {S, H}; % v2 -> v1
metadata_as_v1({S, H})                            -> {S, H}. % v1 -> v1

-spec snapshot_hash(L, H, M, V) -> binary()
    when L :: blockchain_ledger_v1:ledger(),
         H :: non_neg_integer(),
         M :: metadata(),
         V :: non_neg_integer().
snapshot_hash(Ledger, BlockHeightNext, Metadata, VotesNeeded) ->
    %% Find a snapshot hash.  If not enabled or we're unable to determine or
    %% agree on one, just leave it blank, so other nodes can absorb it.
    case blockchain:config(?snapshot_interval, Ledger) of
        {ok, Interval} when (BlockHeightNext - 1) rem Interval == 0 ->
            Hashes = [H || {_, #{snapshot_hash := H}} <- metadata_is_map(Metadata)],
            common_enough_or_default(VotesNeeded, Hashes, <<>>);
        _ ->
            <<>>
    end.

-spec common_enough_or_default(non_neg_integer(), [X], X) -> X.
common_enough_or_default(_, [], Default) ->
    Default;
common_enough_or_default(Threshold, Xs, Default) ->
    %% Looking for highest count AND sufficient agreement:
    case miner_util:list_count_and_sort(Xs) of
        [{X, C}|_] when C >= Threshold -> X;
        [{_, _}|_]                     -> Default % Not common-enough.
    end.

-spec calculate_next_block_time(blockchain:blockchain()) -> integer().
calculate_next_block_time(Chain) ->
    calculate_next_block_time(Chain, false).

-spec calculate_next_block_time(blockchain:blockchain(), boolean()) -> integer().
calculate_next_block_time(Chain, Subsequent) ->
    Now = erlang:system_time(seconds),
    Ledger = blockchain:ledger(Chain),
    {ok, BlockTime0} = blockchain:config(?block_time, Ledger),
    BlockTime = BlockTime0 div 1000,
    {ok, #block_info_v2{time=LastBlockTime, height=Height}} = blockchain:head_block_info(Chain),
    LastBlockTimestamp = case Height of
                             1 ->
                                 %% make up a plausible time for the genesis block
                                 Now;
                             _ ->
                                 LastBlockTime
                         end,
    %% mimic snapshot_take functionality for block range window
    %% blockchain_core:blockchain_ledger_snapshot_v1
    #{election_height := ElectionHeight} = blockchain_election:election_info(Ledger),
    GraceBlocks =
        case blockchain:config(?sc_grace_blocks, Ledger) of
            {ok, GBs} ->
                GBs;
            {error, not_found} ->
                0
        end,
    DLedger = blockchain_ledger_v1:mode(delayed, Ledger),
    {ok, DHeight0} = blockchain_ledger_v1:current_height(DLedger),
    {ok, #block_info_v2{election_info={_, DHeight}}} = blockchain:get_block_info(DHeight0, Chain),

    %% mimic snapshot_take functionality for block range window
    SnapshotStartHeight = max(1, min(DHeight, ElectionHeight - GraceBlocks) - 1),
    SnapshotResult = get_average_block_time(Height, SnapshotStartHeight, BlockTime, LastBlockTimestamp, Chain),
    %% original logic for calculationg block range window
    StabilizationHeight0 = application:get_env(miner, stabilization_period, 0),
    StabilizationHeight = max(1, Height - StabilizationHeight0 + 1),
    StabilizationResults = get_average_block_time(Height, StabilizationHeight, BlockTime, LastBlockTimestamp, Chain),
    %% grab the times with the largest positive amplitude, if amplitudes match grab the longest block history avgtime
    OrderByHistory = lists:reverse(lists:keysort(2, [StabilizationResults, SnapshotResult])),
    {_Amplitude, AvgBlockTime0, BlockRange0} = lists:max([{(A - BlockTime), A, R} || {A, R} <- [StabilizationResults, SnapshotResult]]),
    lager:info("Selected {~p,~p} from ~p", [AvgBlockTime0, BlockRange0, OrderByHistory]),
    NextBlockTime0 = get_next_block_time({AvgBlockTime0, BlockRange0}, BlockTime, LastBlockTimestamp),
    NextBlockTime = case Subsequent of
        true ->
            BlockRange = BlockRange0 + 1,
            AvgBlockTime = (AvgBlockTime0 * BlockRange0 + (NextBlockTime0 - Now)) / BlockRange,
            lager:info("# blocks ~p || average block times ~p difference ~p", [BlockRange, AvgBlockTime, BlockTime - AvgBlockTime]),
            get_next_block_time({AvgBlockTime, BlockRange}, BlockTime, NextBlockTime0);
        false ->
            lager:info("# blocks ~p || average block times ~p difference ~p", [BlockRange0, AvgBlockTime0, BlockTime - AvgBlockTime0]),
            NextBlockTime0
    end,
    lager:info("Next block timeout @ ~p in ~ps", [NextBlockTime, NextBlockTime - Now]),
    NextBlockTime.

%% set next block timer if not already done, used for backwards compatability assumes if block_timer is
%% set correctly then late_block_timer is also
-spec set_next_block_timer(map()) -> map() | ok.
set_next_block_timer(State=#state{blockchain=Chain, target_block_time=undefined}) ->
    Now = erlang:system_time(seconds),
    TargetBlockTime = calculate_next_block_time(Chain),
    NextBlockTime = max(0, TargetBlockTime - Now),
    lager:info("Set block timeout to ~p in ~ps", [TargetBlockTime, NextBlockTime]),
    set_block_timers(State#state{target_block_time = TargetBlockTime}, NextBlockTime);
set_next_block_timer(State=#state{block_timer=BlockTimer, target_block_time=TargetBlockTime}) ->
    %% not to block the critical path
    erlang:read_timer(BlockTimer, [{async, true}]),
    receive
        {read_timer, _TimerRef, CurrentTime} ->
            Now = erlang:system_time(seconds),
            NextBlockTime = max(0, TargetBlockTime - Now),
            case CurrentTime of
                false ->
                    lager:info("Set block timeout to ~p in ~ps", [TargetBlockTime, NextBlockTime]),
                    set_block_timers(State, NextBlockTime);
                _ ->
                    %% timer is ticking, let it be
                    lager:info("Current block timer has ~ps remaining", [CurrentTime div 1000]),
                    ok
            end
    end.

%% separate to deduplicate code
-spec set_block_timers(map(), non_neg_integer()) -> map().
set_block_timers(State, NextBlockTime)  ->
    lager:info("Setting next block timer to ~ps", [NextBlockTime]),
    Timer = erlang:send_after(NextBlockTime * 1000, self(), block_timeout),
    erlang:cancel_timer(State#state.late_block_timer),
    LateBlockTimeout = application:get_env(miner, late_block_timeout_seconds, 120),
    LateTimer = erlang:send_after((LateBlockTimeout + NextBlockTime) * 1000, self(), late_block_timeout),
    State#state{block_timer=Timer, late_block_timer=LateTimer}.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

get_average_block_time(Height, StartHeight, BlockTime, LastBlockTimestamp, Chain) ->
    {ActualStartHeight, StartBlockTime} = case Height > StartHeight of
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
    BlockRange = max(Height - ActualStartHeight, 1),
    AvgBlockTime = case StartBlockTime of
        undefined ->
            BlockTime;
        _ ->
            (LastBlockTimestamp - StartBlockTime) / BlockRange
    end,
    {AvgBlockTime, BlockRange}.

get_next_block_time({AvgBlockTime, BlockRange}, BlockTime, LastBlockTimestamp) ->
    Now = erlang:system_time(seconds),
    DifferenceInTime = (BlockTime - AvgBlockTime) * BlockRange,
    BlockTimeDeviation =
        case DifferenceInTime of
            N when N > 0 ->
                min(1, catchup_time(abs(N)));
            N ->
                -1 * catchup_time(abs(N))
        end,
    %% if chain has been stopped longer then LastBlockTimeout prevent 0 NextBlockTime
    max(Now, LastBlockTimestamp) + BlockTime + BlockTimeDeviation.

%% input in fractional seconds, the number of seconds between the
%% target block time and the average total time over the target period
%% output in seconds of adjustment to apply to the block time target

%% when drift is small or 0, let it accumulate for a bit
catchup_time(N) when N < 0.001 ->
    0;
%% try and catch up within 10 blocks, max 10 seconds
catchup_time(N) ->
    min(10, ceil(N / 10)).


%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Confirm changes to make catchup_time proportional
catchup_time_test() ->
    ?assertEqual(catchup_time(0.0005), 0),
    ?assertEqual(catchup_time(0.01), 1),
    ?assertEqual(catchup_time(0.015), 2),
    ?assertEqual(catchup_time(0.02), 2),
    ?assertEqual(catchup_time(0.05), 5),
    ?assertEqual(catchup_time(0.09), 9),
    ?assertEqual(catchup_time(0.090001), 10),
    ?assertEqual(catchup_time(0.1), 10),
    ?assertEqual(catchup_time(1), 10).

-endif.
