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
    initial_dkg/2,
    relcast_info/1,
    relcast_queue/1,
    consensus_pos/0,
    in_consensus/0,
    hbbft_status/0,
    hbbft_skip/0,
    dkg_status/0,
    sign_genesis_block/2,
    genesis_block_done/3,
    create_block/3,
    signed_block/2
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
    dkg_group :: undefined | pid(),
    consensus_pos :: undefined | pos_integer(),
    batch_size = 500 :: pos_integer(),
    config_proxy ::  pid() | undefined,
    gps_signal :: ebus:filter_id(),
    add_gateway_signal :: ebus:filter_id(),
    blockchain :: undefined | blockchain:blockchain(),
    %% but every miner keeps a timer reference?
    block_timer = make_ref() :: reference(),
    block_time = 15000 :: number(),
    %% TODO: this probably doesn't have to be here
    curve :: 'SS512',
    dkg_await :: undefined | {reference(), term()}
}).

-include_lib("blockchain/include/blockchain.hrl").

%% DBus helper macros
-define(MINER_OBJECT_PATH, "/").
-define(MINER_INTERFACE, "com.helium.Miner").
-define(MINER_OBJECT(M), ?MINER_INTERFACE ++ "." ++ M).
-define(MINER_MEMBER_ADD_GW_STATUS, "AddGatewayStatus").

-define(CONFIG_OBJECT_PATH, "/").
-define(CONFIG_OBJECT_INTERFACE, "com.helium.Config").
-define(CONFIG_OBJECT(M), ?CONFIG_OBJECT_INTERFACE ++ "." ++ M).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% @doc
%% @end
%%--------------------------------------------------------------------
-spec assert_loc_txn(NewLocation::h3:h3index()) -> {ok, binary()} | {error, term()}.
assert_loc_txn(NewLocation) ->
    gen_server:call(?MODULE, {assert_loc_txn, NewLocation}).

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
                    O = maps:map(fun(_, V) ->
                                         [  erlang:binary_to_term(Value) || Value <- V]
                                 end, Outbound),
                    I = [{Index,binary_to_term(B)} || {Index, B} <- Inbound],
                    #{inbound => I,
                      outbound => O}
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
-spec sign_genesis_block(GenesisBlock :: binary(),
                         PrivKey :: tpke_privkey:privkey()) -> {ok, libp2p_crypto:pubkey_bin(), binary()}.
sign_genesis_block(GenesisBlock, PrivKey) ->
    gen_server:call(?MODULE, {sign_genesis_block, GenesisBlock, PrivKey}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec genesis_block_done(GenesisBlock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         PrivKey :: tpke_privkey:privkey()) -> ok.
genesis_block_done(GenesisBlock, Signatures, PrivKey) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures, PrivKey}).

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
    %% this should be a call so we don't loose state
    gen_server:call(?MODULE, {signed_block, Signatures, BinBlock}, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    Curve = proplists:get_value(curve, Args),
    BlockTime = proplists:get_value(block_time, Args),
    BatchSize = proplists:get_value(batch_size, Args),
    ok = blockchain_event:add_handler(self()),

    case proplists:get_value(use_ebus, Args) of
        true ->
            {ok, SystemBus} = ebus:system(),
            {ok, ConfigProxy} = ebus_proxy:start_link(SystemBus, "com.helium.Config", []),
            {ok, GPSSignal} = ebus_proxy:add_signal_handler(ConfigProxy, "/",
                                                            ?CONFIG_OBJECT(?CONFIG_MEMBER_POSITION),
                                                            self(), gps_location),
            {ok, AddGwSignal} = ebus_proxy:add_signal_handler(ConfigProxy, "/",
                                                              ?CONFIG_OBJECT(?CONFIG_MEMBER_ADD_GW),
                                                              self(), add_gateway_request);
        false ->
            GPSSignal = 0,
            AddGwSignal = 0,
            ConfigProxy = undefined
    end,

    self() ! maybe_restore_consensus,

    {ok, #state{curve=Curve,
                block_time=BlockTime,
                batch_size=BatchSize,
                gps_signal=GPSSignal,
                add_gateway_signal=AddGwSignal,
                config_proxy=ConfigProxy}}.

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
            State=#state{blockchain=Chain}) when Chain /= undefined ->
    %% This can actually be a stale message, in which case we'd produce a block with a garbage timestamp
    %% This is not actually that big of a deal, since it won't be accepted, but we can short circuit some effort
    %% by checking for a stale hash
    {ok, CurrentBlock} = blockchain:head_block(Chain),
    {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
    %% we expect every stamp to contain the same block hash
    case lists:usort([ X || {_, {_, X}} <- Stamps ]) of
        [CurrentBlockHash] ->
            SortedTransactions = lists:sort(fun blockchain_txn:sort/2, Transactions),
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
            {reply, {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), BinNewBlock, Signature, ValidTransactions ++ InvalidTransactions}, State};
        [_OtherBlockHash] ->
            {reply, {error, stale_hash}, State};
        List ->
            lager:warning("got unexpected block hashes in stamp information ~p", [List]),
            {reply, {error, multiple_hashes}, State}
    end;
handle_call({signed_block, Signatures, Tempblock}, _From, State=#state{consensus_group=ConsensusGroup,
                                                                       blockchain=Chain,
                                                                       block_time=BlockTime}) when ConsensusGroup /= undefined ->
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
            lager:info("sending the gossipped block to other workers"),
            Swarm = blockchain_swarm:swarm(),
            libp2p_group_gossip:send(
              libp2p_swarm:gossip_group(Swarm),
              ?GOSSIP_PROTOCOL,
              blockchain_gossip_handler:gossip_data(Swarm, Block)
             ),
            ok = blockchain_worker:notify({add_block, blockchain_block:hash_block(Block), true}),
            {reply, ok, State#state{block_timer=Ref}};
        Error ->
            lager:error("signed_block, error: ~p", [Error]),
            {reply, ok, State}
    end;
handle_call(in_consensus, _From, State=#state{consensus_pos=Pos}) ->
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
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, PrivKey}, _From, State = #state{batch_size=BatchSize,
                                                                                                 block_time=BlockTime}) ->
    GenesisBlock = blockchain_block:deserialize(BinaryGenesisBlock),
    SignedGenesisBlock = blockchain_block:set_signatures(GenesisBlock, Signatures),
    lager:notice("Got a signed genesis block: ~p", [SignedGenesisBlock]),

    case State#state.dkg_await of
        undefined -> ok;
        From -> gen_server:reply(From, ok)
    end,

    ok = blockchain_worker:integrate_genesis_block(SignedGenesisBlock),
    N = blockchain_worker:num_consensus_members(),
    F = ((N-1) div 3),
    {ok, ConsensusAddrs} = blockchain_worker:consensus_addrs(),
    Chain = blockchain_worker:blockchain(),
    GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      Chain]],
    %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
    Ref = erlang:send_after(BlockTime, self(), block_timeout),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus", libp2p_group_relcast, GroupArg),
    lager:info("~p. Group: ~p~n", [self(), Group]),
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                         {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
    %% NOTE: I *think* this is the only place to store the chain reference in the miner state
    {reply, ok, State#state{consensus_group=Group, block_timer=Ref, blockchain=Chain}};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

%% TODO: how to restore state when consensus group changes
%% presumably if there's a crash and the consensus members changed, this becomes pointless
handle_info(maybe_restore_consensus, State) ->
    Chain = blockchain_worker:blockchain(),
    case Chain of
        undefined ->
            {noreply, State};
        Chain ->
            Ledger = blockchain:ledger(Chain),
            case blockchain_ledger_v1:consensus_members(Ledger) of
                {error, _} ->
                    {noreply, State#state{blockchain=Chain}};
                {ok, Members} ->
                    ConsensusAddrs = lists:sort(Members),
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
                            %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
                            {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus", libp2p_group_relcast, GroupArg),
                            lager:info("~p. Group: ~p~n", [self(), Group]),
                            ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                            {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
                            {noreply, State#state{consensus_group=Group, block_timer=Ref, consensus_pos=Pos, blockchain=Chain}};
                        false ->
                            {noreply, State#state{blockchain=Chain}}
                    end
            end
    end;
handle_info(block_timeout, State) ->
    lager:info("block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    {noreply, State};
handle_info({blockchain_event, {add_block, Hash, Sync}},
            State=#state{consensus_group=ConsensusGroup,
                         blockchain=Chain,
                         block_time=BlockTime}) when ConsensusGroup /= undefined andalso
                                                     Chain /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
    erlang:cancel_timer(State#state.block_timer),
    NewState = case blockchain:get_block(Hash, Chain) of
                   {ok, Block} ->
                       %% XXX: the 0 default is probably incorrect here, but it would be rejected in the hbbft handler anyway so...
                       NextRound = blockchain_block:hbbft_round(Block) + 1,
                       libp2p_group_relcast:handle_input(ConsensusGroup, {next_round, NextRound, blockchain_block:transactions(Block), Sync}),
                       Ref = set_next_block_timer(Chain, BlockTime),
                       State#state{block_timer=Ref};
                   {error, Reason} ->
                       lager:error("Error, Reason: ~p", [Reason]),
                       State
               end,
    {noreply, NewState};
handle_info({blockchain_event, {add_block, _Hash, _Sync}},
            State=#state{consensus_group=ConsensusGroup,
                         blockchain=Chain}) when ConsensusGroup == undefined andalso
                                                 Chain /= undefined ->
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
do_initial_dkg(GenesisTransactions, Addrs, State=#state{curve=Curve}) ->
    SortedAddrs = lists:sort(Addrs),
    lager:info("SortedAddrs: ~p", [SortedAddrs]),
    N = blockchain_worker:num_consensus_members(),
    lager:info("N: ~p", [N]),
    F = ((N-1) div 3),
    lager:info("F: ~p", [F]),
    ConsensusAddrs = lists:sublist(SortedAddrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
    MyAddress = blockchain_swarm:pubkey_bin(),
    lager:info("MyAddress: ~p", [MyAddress]),
    case lists:member(MyAddress, ConsensusAddrs) of
        true ->
            lager:info("Preparing to run DKG"),
            %% in the consensus group, run the dkg
            GenesisBlockTransactions = GenesisTransactions ++ [blockchain_txn_consensus_group_v1:new(ConsensusAddrs)],
            GenesisBlock = blockchain_block_v1:new_genesis_block(GenesisBlockTransactions),
            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            miner_util:index_of(MyAddress, ConsensusAddrs),
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Curve,
                                            blockchain_block:serialize(GenesisBlock),
                                            {miner, sign_genesis_block},
                                            {miner, genesis_block_done}]],
            %% make a simple hash of the consensus members
            DKGHash = base58:binary_to_base58(crypto:hash(sha, term_to_binary(ConsensusAddrs))),
            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "dkg-"++DKGHash, libp2p_group_relcast, GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            Pos = miner_util:index_of(MyAddress, ConsensusAddrs),
            lager:info("Address: ~p, ConsensusWorker pos: ~p", [MyAddress, Pos]),
            {true, State#state{consensus_pos=Pos, dkg_group=DKGGroup}};
        false ->
            {false, State}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_assert_location(h3:index(), h3:resolution(), blockchain:blockchain()) -> ok.
maybe_assert_location(_, Resolution, _) when Resolution < ?H3_MINIMUM_RESOLUTION ->
    %% wait for a better resolution
    ok;
maybe_assert_location(Location, _Resolution, Chain) ->
    Address = blockchain_swarm:pubkey_bin(),
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(Address, Ledger) of
        {error, _} ->
            ok;
        {ok, GwInfo} ->
            OwnerAddress = blockchain_ledger_gateway_v1:owner_address(GwInfo),
            case blockchain_ledger_gateway_v1:location(GwInfo) of
                undefined ->
                    %% no location, try submitting the transaction
                    lager:info("submitting assert location with h3 index ~p", [Location]),
                    blockchain_worker:assert_location_request(OwnerAddress, Location);
                OldLocation ->
                    case {OldLocation, Location} of
                        {Old, New} when Old == New ->
                            ok;
                        {Old, New} ->
                            try (h3:get_resolution(New) < h3:get_resolution(Old) andalso h3:parent(Old, h3:get_resolution(New)) == New) of
                                true ->
                                    %% new index is a parent of the old one
                                    ok;
                                false ->
                                    %% check if the parent at resolution H3_MINIMUM_RESOLUTION actually differs
                                    case h3:parent(New, ?H3_MINIMUM_RESOLUTION) /= h3:parent(Old, ?H3_MINIMUM_RESOLUTION) of
                                        true ->
                                            lager:info("submitting assert location with h3 index ~p", [Location]),
                                            blockchain_worker:assert_location_request(OwnerAddress, Location);
                                        false ->
                                            ok
                                    end
                            catch
                                TypeOfError:Exception ->
                                    lager:error("No Parent from H3, TypeOfError: ~p, Exception: ~p", [TypeOfError, Exception]),
                                    ok
                            end
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec signal_add_gateway_status(string(), #state{}) -> ok.
signal_add_gateway_status(_, #state{config_proxy=undefined}) ->
    ok;
signal_add_gateway_status(Status, _State=#state{config_proxy=Proxy}) ->
    {ok, Msg} = ebus_message:new_signal(?MINER_OBJECT_PATH,
                                        ?MINER_OBJECT(?MINER_MEMBER_ADD_GW_STATUS)),
    ok = ebus_message:append_args(Msg, [string], [Status]),
    ok = ebus:send(ebus_proxy:bus(Proxy), Msg),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
set_next_block_timer(Chain, BlockTime) ->
    {ok, HeadBlock} = blockchain:head_block(Chain),
    LastBlockTimestamp = blockchain_block:time(HeadBlock),
    NextBlockTime = max(0, (LastBlockTimestamp + (BlockTime div 1000)) - erlang:system_time(seconds)),
    lager:info("Next block after ~p is in ~p seconds", [LastBlockTimestamp, NextBlockTime]),
    erlang:send_after(NextBlockTime * 1000, self(), block_timeout).
