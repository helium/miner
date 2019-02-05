%%%-------------------------------------------------------------------

%% @doc miner
%% @end
%%%-------------------------------------------------------------------
-module(miner).

-behavior(gen_server).

-include_lib("blockchain/include/blockchain.hrl").

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
          dkg_await :: undefined | {reference(), term()},
          election_interval :: pos_integer(),
          current_dkg = undefined :: undefined | pos_integer(),
          current_height = -1 :: integer()
         }).

-export([start_link/1,
         initial_dkg/2,
         relcast_info/0,
         relcast_queue/0,
         consensus_pos/0,
         in_consensus/0,
         hbbft_status/0,
         hbbft_skip/0,
         dkg_status/0,
         sign_genesis_block/2,
         genesis_block_done/4,
         election_done/4,
         create_block/3,
         signed_block/2
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% DBus helper macros
-define(MINER_OBJECT_PATH, "/").
-define(MINER_INTERFACE, "comhelium.Miner").
-define(MINER_OBJECT(M), ?MINER_INTERFACE ++ "." ++ M).
-define(MINER_MEMBER_ADD_GW_STATUS, "AddGatewayStatus").

-define(CONFIG_OBJECT_PATH, "/").
-define(CONFIG_OBJECT_INTERFACE, "com.helium.Config").
-define(CONFIG_OBJECT(M), ?CONFIG_OBJECT_INTERFACE ++ "." ++ M).
-define(CONFIG_MEMBER_POSITION, "Position").
-define(CONFIG_MEMBER_ADD_GW, "AddGateway").

%% H3/assert_location
-define(H3_MINIMUM_RESOLUTION, 9).

%% ==================================================================
%% API calls
%% ==================================================================
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(Args) ->
    Curve = proplists:get_value(curve, Args),
    BlockTime = proplists:get_value(block_time, Args),
    BatchSize = proplists:get_value(batch_size, Args),
    %% TODO: move this into the the chain
    Interval = proplists:get_value(election_interval, Args, 30),
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

    {ok, #state{curve = Curve,
                block_time = BlockTime,
                batch_size = BatchSize,
                gps_signal = GPSSignal,
                add_gateway_signal = AddGwSignal,
                config_proxy = ConfigProxy,
                election_interval = Interval}}.

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
relcast_info() ->
    case gen_server:call(?MODULE, consensus_group, 60000) of
        undefined -> #{};
        Pid ->
            libp2p_group_relcast:info(Pid)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
relcast_queue() ->
    case gen_server:call(?MODULE, consensus_group, 60000) of
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
                   Txns :: blockchain_transactions:transactions(),
                   HBBFTRound :: non_neg_integer()) -> {ok, libp2p_crypto:pubkey_bin(), binary(), binary(), blockchain_transactions:transactions()} | {error, term()}.
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
-spec genesis_block_done(GenesisBLock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         Members :: [libp2p_crypto:address()],
                         PrivKey :: tpke_privkey:privkey()) -> ok.
genesis_block_done(GenesisBlock, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures, Members, PrivKey}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec election_done(binary(), [{libp2p_crypto:address(), binary()}],
                    [libp2p_crypto:address()], tpke_privkey:privkey()) -> ok.
election_done(SignedArtifact, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {election_done, SignedArtifact, Signatures, Members, PrivKey}).

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

%% ==================================================================
%% API casts
%% ==================================================================

%% ==================================================================
%% handle_call functions
%% ==================================================================
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
            SortedTransactions = lists:sort(fun blockchain_transactions:sort/2, Transactions),
            {ValidTransactions, InvalidTransactions} = blockchain_transactions:validate(SortedTransactions, blockchain:ledger(Chain)),
            %% populate this from the last block, unless the last block was the genesis block in which case it will be 0
            LastBlockTimestamp = maps:get(block_time, blockchain_block:meta(CurrentBlock), 0),
            BlockTime = miner_util:median([ X || {_, {X, _}} <- Stamps, X > LastBlockTimestamp]),
            lager:info("new block time is ~p", [BlockTime]),
            MetaData = #{hbbft_round => HBBFTRound, block_time => BlockTime},
            NewBlock = blockchain_block:new(CurrentBlockHash,
                                            blockchain_block:height(CurrentBlock) + 1,
                                            ValidTransactions,
                                            << >>,
                                            MetaData),
            {ok, MyPubKey, SignFun} = blockchain_swarm:keys(),
            Signature = SignFun(term_to_binary(NewBlock)),
            %% XXX: can we lose state here if we crash and recover later?
            lager:info("Worker:~p, Created Block: ~p, Txns: ~p", [self(), NewBlock, ValidTransactions]),
            %% return both valid and invalid transactions to be deleted from the buffer
            {reply, {ok, libp2p_crypto:pubkey_to_bin(MyPubKey), term_to_binary(NewBlock), Signature, ValidTransactions ++ InvalidTransactions}, State};
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
    Block = blockchain_block:sign_block(term_to_binary(Signatures), binary_to_term(Tempblock)),
    case blockchain:add_block(Block, Chain) of
        ok ->
            erlang:cancel_timer(State#state.block_timer),
            Ref = set_next_block_timer(Chain, BlockTime),
            lager:info("sending the gossiped block to other workers"),
            Swarm = blockchain_swarm:swarm(),
            Address = blockchain_swarm:pubkey_bin(),
            libp2p_group_gossip:send(
              libp2p_swarm:gossip_group(Swarm),
              ?GOSSIP_PROTOCOL,
              term_to_binary({block, Address, Block})
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
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, Members, PrivKey}, _From,
            #state{batch_size = BatchSize,
                   block_time = BlockTime} = State) ->
    GenesisBlock = binary_to_term(BinaryGenesisBlock),
    SignedGenesisBlock = blockchain_block:sign_block(term_to_binary(Signatures), GenesisBlock),
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

    Block0 = binary_to_term(BinaryBlock),
    Block = blockchain_block:sign_block(term_to_binary(Signatures), Block0),


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
                {ok, B} = libp2p_group_relcast:handle_command(P, get_buf),
                B;
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
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.

%% ==================================================================
%% handle_cast functions
%% ==================================================================
handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

%% ==================================================================
%% handle_info functions
%% ==================================================================
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
            State=#state{consensus_group = ConsensusGroup,
                         election_interval = Interval,
                         current_height = CurrHeight,
                         blockchain = Chain,
                         block_time = BlockTime}) when ConsensusGroup /= undefined andalso
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
                        Round = maps:get(hbbft_round, blockchain_block:meta(Block), 0),
                        NextRound = Round + 1,
                        case Height rem Interval == 0 andalso Height /= 0 of
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
                                %% signal the existing group to stop.
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
    {noreply, NewState};
handle_info({blockchain_event, {add_block, Hash, _Sync}},
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
                            {noreply, State};
                        %% this consensus group has aged out.  for the first draft, we
                        %% grab the block hash and convert it into an integer to use as a
                        %% seed for the random operations that come next.  Then, we use
                        %% that to select a new consensus group deterministically (ish).
                        true ->
                            {noreply, initiate_election(Chain, Hash, Height, State)}
                    end;
                _ ->
                    {noreply, State}
            end;
        {error, Reason} ->
            lager:error("Error, Reason: ~p", [Reason]),
            {noreply, State}
    end;
handle_info({blockchain_event, {add_block, _Hash, _Sync}},
            State=#state{blockchain = Chain}) when Chain == undefined ->
    {noreply, State#state{blockchain = blockchain_worker:blockchain()}};
handle_info({ebus_signal, _, SignalID, Msg}, State=#state{blockchain=Chain, gps_signal=SignalID}) ->
    case ebus_message:args(Msg) of
        {ok, [#{"lat" := Lat,
                "lon" := Lon,
                "h_accuracy" := HorizontalAcc
               }]} ->
            case Chain /= undefined of
                true ->
                    %% pick the best h3 index we can for the resolution
                    {H3Index, Resolution} = miner_util:h3_index(Lat, Lon, HorizontalAcc),
                    maybe_assert_location(H3Index, Resolution, Chain);
                false ->
                    ok
            end;
        {ok, [Args]} ->
            lager:error("Invalid position_signal args: ~p", [Args]);
        {error, Error} ->
            lager:error("Failed to decode position message: ~p", [Error])
    end,
    {noreply, State};
handle_info({ebus_signal, _, SignalID, Msg}, State=#state{add_gateway_signal=SignalID}) ->
    case ebus_message:args(Msg) of
        {ok, [#{
                "addr" := AuthAddress,
                "token" := AuthToken,
                "owner" := OwnerStrAddress
               }]} ->
            catch(signal_add_gateway_status("sending", State)),
            OwnerAddress = libp2p_crypto:b58_to_bin(OwnerStrAddress),
            Result = blockchain_worker:add_gateway_request(OwnerAddress, AuthAddress, AuthToken),
            lager:info("Requested gateway authorization from ~p result: ~p", [AuthAddress, Result]),
            Status = case Result of
                         ok -> "sent";
                         _ -> "send_failed"
                     end,
            catch(signal_add_gateway_status(Status, State));
        {ok, [Args]} ->
            lager:error("Invalid add_gateway_signal args: ~p", [Args]);
        {error, Error} ->
            lager:error("Failed to decode add_gateway_signal message: ~p", [Error])
    end,
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.



%% ==================================================================
%% Internal functions
%% =================================================================

initiate_election(Chain, Hash, Height, State) ->
    Ledger = blockchain:ledger(Chain),
    OrderedGateways = blockchain_election:new_group(Ledger, Hash),
    lager:info("height ~p ordered: ~p", [Height, OrderedGateways]),

    BlockFun =
        fun(N) ->
                NewGroupTxn = [blockchain_txn_gen_consensus_group_v1:new(lists:sublist(OrderedGateways, N))],
                %% no idea what to do here
                MetaData = #{hbbft_round => Height},

                {ok, CurrentBlock} = blockchain:head_block(Chain),
                {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
                blockchain_block:new(CurrentBlockHash,
                                     blockchain_block:height(CurrentBlock) + 1,
                                     NewGroupTxn,
                                     << >>,
                                     MetaData)
        end,
    {_, State1} = do_dkg(OrderedGateways, BlockFun, sign_genesis_block,
                         election_done, State#state{current_height = Height}),
    State1.

do_initial_dkg(GenesisTransactions, Addrs, State) ->
    lager:info("do initial"),
    SortedAddrs = lists:sort(Addrs),
    lager:info("SortedAddrs: ~p", [SortedAddrs]),
    GenesisBlockFun =
        fun(N) ->
                ConsensusAddrs = lists:sublist(SortedAddrs, 1, N),
                lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
                %% in the consensus group, run the dkg
                GenesisBlockTransactions = GenesisTransactions ++
                    [blockchain_txn_gen_consensus_group_v1:new(ConsensusAddrs)],
                MetaData = #{hbbft_round => 0, block_time => 0},
                blockchain_block:new_genesis_block(GenesisBlockTransactions, MetaData)
        end,
    do_dkg(Addrs, GenesisBlockFun, sign_genesis_block, genesis_block_done, State).

do_dkg(Addrs, ArtifactFun, Sign, Done, State=#state{curve = Curve,
                                                 current_height = CurrHeight,
                                                 current_dkg = CurrDkg}) ->
    N = blockchain_worker:num_consensus_members(),
    lager:info("N: ~p", [N]),
    F = ((N-1) div 3),
    lager:info("F: ~p", [F]),
    ConsensusAddrs = lists:sublist(Addrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
    MyAddress = blockchain_swarm:pubkey_bin(),
    Artifact = ArtifactFun(N),
    lager:info("MyAddress: ~p", [MyAddress]),
    case lists:member(MyAddress, ConsensusAddrs) of
        true when CurrDkg /= CurrHeight ->
            lager:info("Preparing to run DKG at height ~p ", [CurrHeight]),
            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            miner_util:index_of(MyAddress, ConsensusAddrs),
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Curve,
                                            term_to_binary(Artifact), %% TODO we need real block serialization
                                            {miner, Sign},
                                            {miner, Done}]],
            %% make a simple hash of the consensus members
            DKGHash = base58:binary_to_base58(crypto:hash(sha, term_to_binary(ConsensusAddrs))),
            DKGCount = integer_to_list(CurrHeight),
            {ok, DKGGroup} = libp2p_swarm:add_group(blockchain_swarm:swarm(),
                                                    "dkg-"++DKGHash++DKGCount,
                                                    libp2p_group_relcast,
                                                    GroupArg),
            ok = libp2p_group_relcast:handle_input(DKGGroup, start),
            Pos = miner_util:index_of(MyAddress, ConsensusAddrs),
            lager:info("height ~p Address: ~p, ConsensusWorker pos: ~p",
                       [CurrHeight, MyAddress, Pos]),
            {true, State#state{consensus_pos = Pos,
                               dkg_group = DKGGroup,
                               current_dkg = CurrHeight}};
        true ->
            lager:info("not restarting DKG"),
            {true, State};
        false ->
            lager:info("not in DKG this round at height ~p", [CurrHeight]),
            {false, State#state{consensus_pos = undefined,
                                consensus_group = undefined,
                                dkg_group = undefined}}
    end.

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

-spec signal_add_gateway_status(string(), #state{}) -> ok.
signal_add_gateway_status(_, #state{config_proxy=undefined}) ->
    ok;
signal_add_gateway_status(Status, _State=#state{config_proxy=Proxy}) ->
    {ok, Msg} = ebus_message:new_signal(?MINER_OBJECT_PATH,
                                        ?MINER_OBJECT(?MINER_MEMBER_ADD_GW_STATUS)),
    ok = ebus_message:append_args(Msg, [string], [Status]),
    ok = ebus:send(ebus_proxy:bus(Proxy), Msg),
    ok.

set_next_block_timer(Chain, BlockTime) ->
    {ok, HeadBlock} = blockchain:head_block(Chain),
    LastBlockTimestamp = maps:get(block_time, blockchain_block:meta(HeadBlock), erlang:system_time(seconds)),
    NextBlockTime = max(0, (LastBlockTimestamp + (BlockTime div 1000)) - erlang:system_time(seconds)),
    lager:info("Next block after ~p is in ~p seconds", [LastBlockTimestamp, NextBlockTime]),
    erlang:send_after(NextBlockTime * 1000, self(), block_timeout).

