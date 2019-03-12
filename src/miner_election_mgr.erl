-module(miner_election_mgr).

-behaviour(gen_server).

%% API
-export([
         start_link/3, % election
         start_link/4, % genesis

         genesis_block_done
         election_done/2,

         dkg_status/0,
         sign_genesis_block/2,
         genesis_block_done/4,
         election_done/4,
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         current_dkg :: undefined | pid(),
         hash :: undefined | binary(),
         initial_height :: undefined | pos_integer(),
         initial_txns :: [any()],
         genesis = false :: boolean(),
         tries = 0 :: integer(),
         timer_ref = undefined | reference()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec sign_genesis_block(GenesisBlock :: binary(),
                         PrivKey :: tpke_privkey:privkey()) -> {ok, libp2p_crypto:pubkey_bin(), binary()}.
sign_genesis_block(GenesisBlock, PrivKey) ->
    gen_server:call(?MODULE, {sign_genesis_block, GenesisBlock, PrivKey}).

-spec genesis_block_done(GenesisBLock :: binary(),
                         Signatures :: [{libp2p_crypto:pubkey_bin(), binary()}],
                         Members :: [libp2p_crypto:address()],
                         PrivKey :: tpke_privkey:privkey()) -> ok.
genesis_block_done(GenesisBlock, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {genesis_block_done, GenesisBlock, Signatures, Members, PrivKey}, infinity).

-spec election_done(binary(), [{libp2p_crypto:address(), binary()}],
                    [libp2p_crypto:address()], tpke_privkey:privkey()) -> ok.
election_done(SignedArtifact, Signatures, Members, PrivKey) ->
    gen_server:call(?MODULE, {election_done, SignedArtifact, Signatures, Members, PrivKey}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% two versions, one for an election, one for the genesis block

init([Chain, Hash, Height]) ->
    %% election version

    %% asynchronously trigger a dkg
    self ! {init, Chain, Hash, Height},

    {ok, #state{}}.

%% in the call handlers, we wait for the dkg to return, and then once
%% it does, we communicate with the miner

handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

%% for the genesis block, since there will be an operator, we don't
%% bother to set up a timeout for the dkg.
handle_info({init, Chain, Hash, Height}, #state{genesis = true} = State) ->

    {noreply, State};
handle_info({init, Chain, Hash, Height}, #state{genesis = false} = State) ->
    Timeout = application:get_env(miner, dkg_timeout, timer:seconds(120)),
    Ref = erlang:send_after(Timeout, self, dkg_timeout),

    {noreply, State#state{timer_ref = Ref}};
handle_info(dkg_timeout, State) ->
    %% kill the running dkg
    %% extract another consensus list
    %% restart the dkg
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

initiate_election(Chain, Hash, Height, State) ->
    Ledger = blockchain:ledger(Chain),
    OrderedGateways = blockchain_election:new_group(Ledger, Hash),
    lager:info("height ~p ordered: ~p", [Height, OrderedGateways]),

    BlockFun =
        fun(N) ->
                NewGroupTxn = [blockchain_txn_consensus_group_v1:new(lists:sublist(OrderedGateways, N))],
                %% no idea what to do here

                {ok, CurrentBlock} = blockchain:head_block(Chain),
                {ok, CurrentBlockHash} = blockchain:head_hash(Chain),
                blockchain_block_v1:new(#{prev_hash => CurrentBlockHash,
                                     height => blockchain_block:height(CurrentBlock) + 1,
                                     hbbft_round => Height,
                                     time => 0,
                                     transactions => NewGroupTxn,
                                     signatures => []})
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
                    [blockchain_txn_consensus_group_v1:new(ConsensusAddrs)],
                blockchain_block:new_genesis_block(GenesisBlockTransactions)
        end,
    do_dkg(SortedAddrs, GenesisBlockFun, sign_genesis_block, genesis_block_done, State).

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
            miner_ebus:send_signal("ConsensusElect", "Elected"),

            GroupArg = [miner_dkg_handler, [ConsensusAddrs,
                                            miner_util:index_of(MyAddress, ConsensusAddrs),
                                            N,
                                            0, %% NOTE: F for DKG is 0
                                            F, %% NOTE: T for DKG is the byzantine F
                                            Curve,
                                            blockchain_block:serialize(Artifact),
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
            miner_ebus:send_signal("ConsensusElect", "Defeated"),
            lager:info("not in DKG this round at height ~p", [CurrHeight]),
            {false, State#state{consensus_pos = undefined,
                                consensus_group = undefined,
                                dkg_group = undefined}}
    end.
