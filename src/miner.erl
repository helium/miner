%%%-------------------------------------------------------------------
%% @doc miner
%% @end
%%%-------------------------------------------------------------------
-module(miner).

-behavior(gen_server).

-record(state, {
          consensus_group :: undefined | pid()
          ,dkg_group :: undefined | pid()
          ,consensus_worker_pos :: undefined | pos_integer()
          ,tempblock :: undefined | blockchain_block:block()
          ,privkey :: undefined | tpke_privkey:privkey()
          ,block_timer = make_ref() :: reference()
          ,candidate_genesis_block :: undefined | blockchain_block:block()
         }).

-export([start_link/0
         ,relcast_info/0
         ,relcast_queue/0
         ,consensus_worker_pos/0
         ,in_consensus_group/0
         ,create_block/1
         ,sign_genesis_block/2
         ,genesis_block_done/3
         ,hbbft_status/0
         ,set_consensus_worker_pos/1
         ,create_hbbft_group/0
         ,start_dkg/0
         ,add_block/1
         ,restore_state/0
         ,set_dkg_group/1
         ,sign_block/1
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% ==================================================================
%% API calls
%% ==================================================================
init([]) ->
    {ok, #state{}}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

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
-spec consensus_worker_pos() -> non_neg_integer().
consensus_worker_pos() ->
    gen_server:call(?MODULE, consensus_worker_pos).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec in_consensus_group() -> boolean().
in_consensus_group() ->
    gen_server:call(?MODULE, in_consensus_group).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_block(blockchain_transaction:transactions()) -> {ok, libp2p_crypto:address(), binary(), binary(), blockchain_transaction:transactions()}.
create_block(Txns) ->
    gen_server:call(?MODULE, {create_block, Txns}).

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
set_consensus_worker_pos(Pos) ->
    gen_server:cast(?MODULE, {set_consensus_worker_pos, Pos}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
create_hbbft_group() ->
    gen_server:cast(?MODULE, create_hbbft_group).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
start_dkg() ->
    gen_server:cast(?MODULE, start_dkg).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
add_block(Block) ->
    gen_server:cast(?MODULE, {add_block, Block}).

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
set_dkg_group(Group) ->
    gen_server:cast(?MODULE, {set_dkg_group, Group}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
sign_block(Signatures) ->
    gen_server:cast(?MODULE, {sign_block, Signatures}).


%% ==================================================================
%% handle_call functions
%% ==================================================================
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
handle_call(consensus_worker_pos, _From, State) ->
    {reply, State#state.consensus_worker_pos, State};
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
handle_call({create_block, Transactions}, _From, State) ->
    CurrentBlock = maps:get(blockchain_worker:head(), blockchain_worker:blocks(), blockchain_worker:genesis_hash()),
    SortedTransactions = lists:sort(fun blockchain_transaction:sort/2, Transactions),
    {ValidTransactions, InvalidTransactions} = blockchain_transaction:validate_transactions(SortedTransactions, blockchain_worker:ledger()),

    NewBlock = blockchain_block:new(blockchain_worker:head(),
                                    blockchain_block:height(CurrentBlock) + 1,
                                    ValidTransactions,
                                    << >>),

    {ok, MyPubKey, SignFun} = libp2p_swarm:keys(blockchain_swarm:swarm()),
    Signature = SignFun(term_to_binary(NewBlock)),

    %% TODO: do this in restore state somehow
    %% ok = blockchain_util:write_data_to_file("tempblock", NewBlock),
    %% XXX can we lose state here if we crash and recover later?

    lager:info("Worker:~p, Created Block: ~p, Txns: ~p", [self(), NewBlock, ValidTransactions]),
    %% return both valid and invalid transactions to be deleted from the buffer
    {reply, {ok, libp2p_crypto:pubkey_to_address(MyPubKey), term_to_binary(NewBlock), Signature, ValidTransactions ++ InvalidTransactions}, State#state{tempblock=NewBlock}};
handle_call(in_consensus_group, _From, State=#state{consensus_worker_pos=Pos}) ->
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
    %% TODO this can only happen at most once
    SignedGenesisBlock = blockchain_block:sign_block(GenesisBlock, term_to_binary(Signatures)),
    lager:notice("Got a signed genesis block: ~p", [SignedGenesisBlock]),
    blockchain_worker:integrate_genesis_block(SignedGenesisBlock),
    {reply, ok, State#state{privkey=PrivKey}};
handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.

%% ==================================================================
%% handle_cast functions
%% ==================================================================
handle_cast(create_hbbft_group, State=#state{privkey=PrivKey}) ->
    N = length(blockchain_worker:consensus_addrs()),
    F = ((N-1) div 3),
    {ok, BatchSize} = application:get_env(blockchain, batch_size),
    GroupArg = [blockchain_hbbft_handler, [blockchain_worker:consensus_addrs(),
                                           State#state.consensus_worker_pos,
                                           N,
                                           F,
                                           BatchSize,
                                           PrivKey,
                                           self()]],
    %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
    Ref = erlang:send_after(application:get_env(blockchain, block_time, 15000), self(), block_timeout),
    {ok, Group} = libp2p_swarm:add_group(blockchain_swarm:swarm(), "consensus", libp2p_group_relcast, GroupArg),
    lager:info("~p. Group: ~p~n", [self(), Group]),

    ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), "blockchain_txn/1.0.0",
                                         {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),

    %% TODO: handle restore state better
    %% ok = blockchain_util:write_data_to_file("pbc_pubkey", tpke_pubkey:serialize(tpke_privkey:public_key(PrivKey))),

    {noreply, State#state{consensus_group=Group, block_timer=Ref}};
handle_cast(start_dkg, State=#state{dkg_group=DKGGroup}) when DKGGroup /= undefined ->
    libp2p_group_relcast:handle_input(DKGGroup, start),
    {noreply, State};
handle_cast({add_block, Block}, State=#state{consensus_group=ConsensusGroup}) when ConsensusGroup /= undefined ->
    %% delete the TempBlock if we had one
    %% tell hbbft to go to the next round
    erlang:cancel_timer(State#state.block_timer),
    libp2p_group_relcast:handle_input(ConsensusGroup, {next_round, blockchain_block:transactions(Block)}),
    Ref = erlang:send_after(application:get_env(blockchain, block_time, 15000), self(), block_timeout),
    {noreply, State#state{tempblock=undefined, block_timer=Ref}};
handle_cast({set_consensus_worker_pos, Pos}, State) ->
    {noreply, State#state{consensus_worker_pos=Pos}};
%% TODO: how to restore state when consensus group changes
%% presumably if there's a crash and the consensus members changed, this becomes pointless
%% handle_cast(restore_state, State) ->
%%     ConsensusAddrs = blockchain_worker:consensus_addrs(),
%%     Pos = blockchain_util:index_of(blockchain_worker:address(), ConsensusAddrs),
%%     N = length(ConsensusAddrs),
%%     F = (N div 3),
%%     {ok, BatchSize} = application:get_env(blockchain, batch_size),
%%     GroupArg = [blockchain_hbbft_handler, [ConsensusAddrs,
%%                                            Pos,
%%                                            N,
%%                                            F,
%%                                            BatchSize,
%%                                            undefined,
%%                                            self()]],
%%     %% TODO generate a unique value (probably based on the public key from the DKG) to identify this consensus group
%%     {ok, Group} = libp2p_swarm:add_group(blockchain_worker:swarm(), "consensus", libp2p_group_relcast, GroupArg),
%%     lager:info("~p. Group: ~p~n", [self(), Group]),
%%     ok = libp2p_swarm:add_stream_handler(blockchain_worker:swarm(), "blockchain_txn/1.0.0",
%%                                          {libp2p_framed_stream, server, [blockchain_txn_handler, self(), Group]}),
%%     Ref = erlang:send_after(application:get_env(blockchain, block_time, 15000), self(), block_timeout),
%%     {noreply, State#state{consensus_group=Group, block_timer=Ref, consensus_worker_pos=Pos}};
handle_cast({set_dkg_group, Group}, State) ->
    {noreply, State#state{dkg_group=Group}};
handle_cast({set_candidate_genesis_block, Block}, State) ->
    %% TODO add an interlock so this is only possible once
    {noreply, State#state{candidate_genesis_block=Block}};
handle_cast({sign_block, Signatures}, State=#state{tempblock=Tempblock}) when Tempblock /= undefined ->
    Block = blockchain_block:sign_block(Tempblock, term_to_binary(Signatures)),
    blockchain_worker:add_block(Block, blockchain_swarm:address()),
    {noreply, State#state{tempblock=undefined}};
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
handle_info(_Msg, State) ->
    lager:warning("unhandled info message ~p", [_Msg]),
    {noreply, State}.
