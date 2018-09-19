%%%-------------------------------------------------------------------
%% @doc miner
%% @end
%%%-------------------------------------------------------------------
-module(miner).

-behavior(gen_server).

-record(state, {
          %% NOTE: a miner may or may not participate in consensus
          consensus_group :: undefined | pid()
          ,dkg_group :: undefined | pid()
          ,consensus_pos :: undefined | pos_integer()
          ,tempblock :: undefined | blockchain_block:block()
          ,privkey :: undefined | tpke_privkey:privkey()
          ,candidate_genesis_block :: undefined | blockchain_block:block()

          %% but every miner keeps a timer reference?
          ,block_timer = make_ref() :: reference()
          ,block_time = 15000 :: pos_integer
          %% TODO: this probably doesn't have to be here
          ,curve :: 'SS512'
          ,dkg_await :: undefined | {reference(), term()}
         }).

-export([start_link/1
         ,initial_dkg/1
         ,relcast_info/0
         ,relcast_queue/0
         ,consensus_pos/0
         ,in_consensus/0
         ,create_block/2
         ,sign_genesis_block/2
         ,genesis_block_done/3
         ,hbbft_status/0
         ,restore_state/0
         ,sign_block/1
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% ==================================================================
%% API calls
%% ==================================================================
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(Args) ->
    Curve = proplists:get_value(curve, Args),
    BlockTime = proplists:get_value(block_time, Args),
    ok = blockchain_event:add_handler(self()),
    {ok, #state{curve=Curve, block_time=BlockTime}}.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
initial_dkg(Addrs) ->
    gen_server:call(?MODULE, {initial_dkg, Addrs}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
relcast_info() ->
    gen_server:call(?MODULE, relcast_info).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
relcast_queue() ->
    gen_server:call(?MODULE, relcast_queue).

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
-spec create_block(blockchain_transaction:transactions(), non_neg_integer()) -> {ok, libp2p_crypto:address(), binary(), binary(), blockchain_transaction:transactions()}.
create_block(Txns, HBBFTRound) ->
    gen_server:call(?MODULE, {create_block, Txns, HBBFTRound}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec sign_genesis_block(binary(), tpke_privkey:privkey()) -> {ok, libp2p_crypto:address(), binary()}.
sign_genesis_block(GenesisBlock, PrivKey) ->
    gen_server:call(?MODULE, {sign_genesis_block, GenesisBlock, PrivKey}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec genesis_block_done(binary(), [{libp2p_crypto:address(), binary()}], tpke_privkey:privkey()) -> ok.
genesis_block_done(GenesisBlock, Signatures, PrivKey) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures, PrivKey}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
%% TODO: spec
hbbft_status() ->
    gen_server:call(?MODULE, hbbft_status).


%% ==================================================================
%% API casts
%% ==================================================================

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
restore_state() ->
    gen_server:cast(?MODULE, restore_state).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
sign_block(Signatures) ->
    gen_server:cast(?MODULE, {sign_block, Signatures}).

%% ==================================================================
%% handle_call functions
%% ==================================================================
handle_call({initial_dkg, Addrs}, From, State) ->
    case do_initial_dkg(Addrs, State) of
        {true, DKGState} ->
            lager:info("Waiting for DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:address()]),
            {noreply, DKGState#state{dkg_await=From}};
        {false, NonDKGState} ->
            lager:info("Not running DKG, From: ~p, WorkerAddr: ~p", [From, blockchain_swarm:address()]),
            {reply, ok, NonDKGState}
    end;
handle_call(relcast_info, _From, State) ->
    case State#state.consensus_group of
        undefined -> {reply, ok, State};
        Pid ->
            Res = (catch libp2p_group_relcast:info(Pid)),
            {reply, Res, State}
    end;
handle_call(relcast_queue, _From, State) ->
    case State#state.consensus_group of
        undefined -> {reply, ok, State};
        Pid ->
            Reply = try libp2p_group_relcast:queues(Pid) of
                        Res ->
                            maps:map(fun(_, V) ->
                                             [ {Index, lists:map(fun erlang:binary_to_term/1, Values)} || {Index, Values} <- V]
                                     end, Res)
                    catch What:Why ->
                              {error, {What, Why}}
                    end,
            {reply, Reply, State}
    end;
handle_call(consensus_pos, _From, State) ->
    {reply, State#state.consensus_pos, State};
handle_call(hbbft_status, _From, State) ->
    Status = case State#state.consensus_group of
                 undefined -> ok;
                 _ ->
                     Ref = make_ref(),
                     ok = libp2p_group_relcast:handle_input(State#state.consensus_group, {status, Ref, self()}),
                     receive
                         {Ref, Result} ->
                             Result
                     after timer:seconds(1) ->
                               {error, timeout}
                     end
             end,
    {reply, Status, State};
handle_call({create_block, Transactions, HBBFTRound}, _From, State) ->
    CurrentBlock = blockchain_worker:head_block(),
    SortedTransactions = lists:sort(fun blockchain_transaction:sort/2, Transactions),
    {ValidTransactions, InvalidTransactions} = blockchain_transaction:validate_transactions(SortedTransactions, blockchain_worker:ledger()),
    MetaData = #{hbbft_round => HBBFTRound},
    NewBlock = blockchain_block:new(blockchain_worker:head_hash(),
                                    blockchain_block:height(CurrentBlock) + 1,
                                    ValidTransactions,
                                    << >>,
                                    MetaData),

    {ok, MyPubKey, SignFun} = libp2p_swarm:keys(blockchain_swarm:swarm()),
    Signature = SignFun(term_to_binary(NewBlock)),
    %% XXX: can we lose state here if we crash and recover later?
    %% XXX: We were writing this tempblock to file before, but not loading it aywhere
    lager:info("Worker:~p, Created Block: ~p, Txns: ~p", [self(), NewBlock, ValidTransactions]),
    %% return both valid and invalid transactions to be deleted from the buffer
    {reply, {ok, libp2p_crypto:pubkey_to_address(MyPubKey), term_to_binary(NewBlock), Signature, ValidTransactions ++ InvalidTransactions}, State#state{tempblock=NewBlock}};
handle_call(in_consensus, _From, State=#state{consensus_pos=Pos}) ->
    Reply = case Pos of
                undefined -> false;
                _ -> true
            end,
    {reply, Reply, State};
handle_call({sign_genesis_block, GenesisBlock, PrivateKey}, _From, State) ->
    {ok, MyPubKey, SignFun} = libp2p_swarm:keys(blockchain_swarm:swarm()),
    Signature = SignFun(GenesisBlock),
    Address = libp2p_crypto:pubkey_to_address(MyPubKey),
    {reply, {ok, Address, Signature}, State#state{privkey=PrivateKey}};
handle_call({genesis_block_done, BinaryGenesisBlock, Signatures, PrivKey}, _From, State) ->
    GenesisBlock = binary_to_term(BinaryGenesisBlock),
    SignedGenesisBlock = blockchain_block:sign_block(term_to_binary(Signatures), GenesisBlock),
    lager:notice("Got a signed genesis block: ~p", [SignedGenesisBlock]),

    case State#state.dkg_await of
        undefined -> ok;
        From -> gen_server:reply(From, ok)
    end,

    ok = blockchain_worker:integrate_genesis_block(SignedGenesisBlock),
    self() ! create_hbbft_group,
    {reply, ok, State#state{privkey=PrivKey}};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.

%% ==================================================================
%% handle_cast functions
%% ==================================================================
%% TODO: how to restore state when consensus group changes
%% presumably if there's a crash and the consensus members changed, this becomes pointless
%% handle_cast(restore_state, State) ->
%%     ConsensusAddrs = blockchain_worker:consensus_addrs(),
%%     Pos = miner_util:index_of(blockchain_swarm:address(), ConsensusAddrs),
%%     N = length(ConsensusAddrs),
%%     F = (N div 3),
%%     {ok, BatchSize} = application:get_env(blockchain, batch_size),
%%     GroupArg = [miner_hbbft_handler, [ConsensusAddrs,
%%                                            Pos,
%%                                            N,
%%                                            F,
%%                                            BatchSize,
%%                                            undefined,
%%                                            self()]],
%%     %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
%%     {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus", libp2p_group_relcast, GroupArg),
%%     lager:info("~p. Group: ~p~n", [self(), Group]),
%%     ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), "blockchain_txn/1.0.0",
%%                                          {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
%%     Ref = erlang:send_after(application:get_env(blockchain, block_time, 15000), self(), block_timeout),
%%     {noreply, State#state{consensus_group=Group, block_timer=Ref, consensus_pos=Pos}};
handle_cast({set_candidate_genesis_block, Block}, State) ->
    %% TODO add an interlock so this is only possible once
    {noreply, State#state{candidate_genesis_block=Block}};
handle_cast({sign_block, Signatures}, State=#state{consensus_group=ConsensusGroup,
                                                   block_time=BlockTime,
                                                   tempblock=Tempblock}) when Tempblock /= undefined
                                                                              andalso ConsensusGroup /= undefined ->
    %% Once a miner gets a sign_block message (only happens if the miner is in consensus group):
    %% * cancel the block timer
    %% * sign the block
    %% * tell hbbft to go to next round
    %% * add the block to blockchain
    %% * make tempblock undefined
    erlang:cancel_timer(State#state.block_timer),
    Block = blockchain_block:sign_block(term_to_binary(Signatures), Tempblock),
    NextRound = maps:get(hbbft_round, blockchain_block:meta(Block), 0) + 1,
    libp2p_group_relcast:handle_input(ConsensusGroup, {next_round, NextRound, blockchain_block:transactions(Block)}),
    Ref = erlang:send_after(BlockTime, self(), block_timeout),
    ok = blockchain_worker:add_block(Block, blockchain_swarm:address()),
    {noreply, State#state{tempblock=undefined, block_timer=Ref}};
handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p, tempblock: ~p", [_Msg, State#state.tempblock]),
    {noreply, State}.

%% ==================================================================
%% handle_info functions
%% ==================================================================
handle_info(block_timeout, State) ->
    lager:info("block timeout"),
    libp2p_group_relcast:handle_input(State#state.consensus_group, start_acs),
    {noreply, State};
handle_info(create_hbbft_group, State=#state{privkey=PrivKey, block_time=BlockTime}) ->
    N = blockchain_worker:num_consensus_members(),
    F = ((N-1) div 3),
    BatchSize = 500,
    GroupArg = [miner_hbbft_handler, [blockchain_worker:consensus_addrs(),
                                      State#state.consensus_pos,
                                      N,
                                      F,
                                      BatchSize,
                                      PrivKey,
                                      self()]],
    %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
    Ref = erlang:send_after(BlockTime, self(), block_timeout),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus", libp2p_group_relcast, GroupArg),
    lager:info("~p. Group: ~p~n", [self(), Group]),
    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), "blockchain_txn/1.0.0",
                                         {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
    %% TODO: handle restore state better
    ok = blockchain_util:atomic_save(filename:join(blockchain:dir(blockchain_worker:blockchain()), "pbc_pubkey"),
                                     term_to_binary(tpke_pubkey:serialize(tpke_privkey:public_key(PrivKey)))),
    {noreply, State#state{consensus_group=Group, block_timer=Ref}};
handle_info({blockchain_event, {add_block, Hash}}, State=#state{consensus_group=ConsensusGroup,
                                                                block_time=BlockTime}) when ConsensusGroup /= undefined ->
    %% NOTE: only the consensus group member must do this
    %% If this miner is in consensus group and lagging on a previous hbbft round, make it forcefully go to next round
    erlang:cancel_timer(State#state.block_timer),
    NewState = case blockchain_worker:get_block(Hash) of
                   {ok, Block} ->
                       %% XXX: the 0 default is probably incorrect here, but it would be rejected in the hbbft handler anyway so...
                       NextRound = maps:get(hbbft_round, blockchain_block:meta(Block), 0) + 1,
                       libp2p_group_relcast:handle_input(ConsensusGroup, {next_round, NextRound, blockchain_block:transactions(Block)}),
                       Ref = erlang:send_after(BlockTime, self(), block_timeout),
                       State#state{block_timer=Ref};
                   {error, Reason} ->
                       lager:error("Error, Reason: ~p", [Reason]),
                       State
               end,
    {noreply, NewState};
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.


%% ==================================================================
%% Internal functions
%% ==================================================================
do_initial_dkg(Addrs, State=#state{curve=Curve}) ->
    SortedAddrs = lists:sort(Addrs),
    lager:info("SortedAddrs: ~p", [SortedAddrs]),
    N = blockchain_worker:num_consensus_members(),
    lager:info("N: ~p", [N]),
    F = ((N-1) div 3),
    lager:info("F: ~p", [F]),
    ConsensusAddrs = lists:sublist(SortedAddrs, 1, N),
    lager:info("ConsensusAddrs: ~p", [ConsensusAddrs]),
    ok = blockchain_worker:consensus_addrs(ConsensusAddrs),
    lager:info("WorkerConsensusAddrs: ~p", [blockchain_worker:consensus_addrs()]),
    MyAddress = blockchain_swarm:address(),
    lager:info("MyAddress: ~p", [MyAddress]),
    case lists:member(MyAddress, ConsensusAddrs) of
        true ->
            lager:info("Preparing to run DKG"),
            %% in the consensus group, run the dkg
            %% TODO: set initial balance elsewhere
            InitialPaymentTransactions = [ blockchain_transaction:new_coinbase_txn(Addr, 5000) || Addr <- Addrs],
            GenesisTransactions = InitialPaymentTransactions ++ [blockchain_transaction:new_genesis_consensus_group(ConsensusAddrs)],
            GenesisBlock = blockchain_block:new_genesis_block(GenesisTransactions),
            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            miner_util:index_of(MyAddress, ConsensusAddrs),
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Curve,
                                            term_to_binary(GenesisBlock), %% TODO we need real block serialization
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
