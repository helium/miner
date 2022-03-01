%%%-------------------------------------------------------------------
%%% @doc
%%% listens for block events, inspects the POCs in the block metadata
%%% and for each of our own keys which made it into the block
%%% kick off a POC
%%% @end
%%%-------------------------------------------------------------------
-module(miner_poc_mgr).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(ACTIVE_POCS, active_pocs).
-define(KEYS, keys).
-define(KEY_PROPOSALS, key_proposals).
-define(ADDR_HASH_FP_RATE, 1.0e-9).
-define(POC_DB_CF, {?MODULE, poc_db_cf_handle}).
-ifdef(TEST).
%% lifespan of a POC, after which we will
%% submit the receipts txn and delete the local poc data
-define(POC_TIMEOUT, 4).
-else.
-define(POC_TIMEOUT, 10).
-endif.


%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    make_ets_table/0,
    cached_local_poc_key/1,
    save_local_poc_keys/2,
    check_target/3,
    report/4,
    active_pocs/0,
    local_poc_key/1,
    local_poc/1,
    save_poc_key_proposals/3,
    delete_cached_local_poc_key_proposal/1,
    get_random_poc_key_proposals/1,
    cached_local_poc_key_proposals/0
]).
%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ------------------------------------------------------------------
%% record defs and macros
%% ------------------------------------------------------------------
-record(addr_hash_filter, {
    start :: pos_integer(),
    height :: pos_integer(),
    byte_size :: pos_integer(),
    salt :: binary(),
    bloom :: bloom_nif:bloom()
}).

-record(poc_local_key_data, {
    receive_height :: non_neg_integer(),
    keys :: keys()
}).

-record(poc_key_proposal, {
    receive_height :: non_neg_integer(),
    key :: key_proposal(),
    address :: libp2p_crypto:pubkey_bin()
}).

-record(local_poc, {
    onion_key_hash :: binary(),
    block_hash :: binary() | undefined,
    keys :: keys() | undefined,
    target :: libp2p_crypto:pubkey_bin(),
    onion :: binary() | undefined,
    secret :: binary() | undefined,
    responses = #{},
    challengees = [] :: [libp2p_crypto:pubkey_bin()],
    packet_hashes = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    start_height :: non_neg_integer()
}).

-record(state, {
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    chain :: undefined | blockchain:blockchain(),
    ledger :: undefined | blockchain:ledger(),
    sig_fun :: undefined | libp2p_crypto:sig_fun(),
    pub_key = undefined :: undefined | libp2p_crypto:pubkey_bin(),
    addr_hash_filter :: undefined | #addr_hash_filter{}
}).
-type state() :: #state{}.
-type keys() :: #{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}.
-type poc_key() :: binary().
-type cached_local_poc_local_key_data() :: #poc_local_key_data{}.
-type cached_local_poc_key_type() :: {POCKey :: poc_key(), POCKeyData :: #poc_local_key_data{}}.
-type key_proposals() :: [key_proposal()].
-type key_proposal() :: binary().
-type cached_key_proposal() :: #poc_key_proposal{}.

-type local_poc() :: #local_poc{}.
-type local_pocs() :: [local_poc()].
-type local_poc_key() :: binary().

-export_type([keys/0, local_poc_key/0, cached_local_poc_local_key_data/0, cached_local_poc_key_type/0, local_poc/0, local_pocs/0]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------

-spec local_poc_key(local_poc()) -> local_poc_key().
local_poc_key(LocalPoC) ->
    LocalPoC#local_poc.onion_key_hash.

-spec start_link(#{}) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []) of
        {ok, Pid} ->
            %% if we have an ETS table reference, give ownership to the new process
            %% we likely are the `heir', so we'll get it back if this process dies
            case maps:find(tab1, Args) of
                error ->
                    ok;
                {ok, Tab1} ->
                    true = ets:give_away(Tab1, Pid, undefined)
            end,
            case maps:find(tab2, Args) of
                error ->
                    ok;
                {ok, Tab2} ->
                    true = ets:give_away(Tab2, Pid, undefined)
            end,
            {ok, Pid};
        Other ->
            Other
    end.

-spec make_ets_table() -> [atom()].
make_ets_table() ->
    Tab1 = ets:new(
        ?KEYS,
        [
            named_table,
            public,
            {heir, self(), undefined}
        ]
    ),
    Tab2 = ets:new(
        ?KEY_PROPOSALS,
        [
            named_table,
            public,
            {heir, self(), undefined}
        ]
    ),
    [Tab1, Tab2].

-spec save_local_poc_keys(CurHeight :: non_neg_integer(), [keys()]) -> ok.
save_local_poc_keys(CurHeight, KeyList) ->
    %% these are the keys ( public & private ) generated by this validator
    %% as part of submitting a new heartbeat
    %% push each key set to ets with a hash of the public key as key
    %% each new block we will then check if any of our cached keys made it into the block
    %% and if so retrieve the private key for each
    [
        begin
            #{public := PubKey} = Keys,
            OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(PubKey)),
            POCKeyRec = #poc_local_key_data{receive_height = CurHeight, keys = Keys},
            lager:info("caching local poc keys with hash ~p", [OnionKeyHash]),
            _ = cache_poc_key(OnionKeyHash, POCKeyRec)
        end
        || Keys <- KeyList
    ],
    ok.

-spec cached_local_poc_key(poc_key()) -> {ok, cached_local_poc_key_type()} | false.
cached_local_poc_key(ID) ->
    case ets:lookup(?KEYS, ID) of
        [Res] -> {ok, Res};
        _ -> false
    end.

-spec active_pocs()->[local_poc()].
active_pocs() ->
    gen_server:call(?MODULE, {active_pocs}).

-spec check_target(
    Challengee :: libp2p_crypto:pubkey_bin(),
    BlockHash :: binary(),
    OnionKeyHash :: binary()
) -> false | {true, binary()} | {error, any()}.
check_target(Challengee, BlockHash, OnionKeyHash) ->
    lager:info("*** check target with key ~p", [OnionKeyHash]),
    LocalPOC = e2qc:cache(
                local_pocs,
                OnionKeyHash,
                30,
                fun() -> ?MODULE:local_poc(OnionKeyHash) end
    ),
    lager:info("*** e2qc local POC check target result ~p", [LocalPOC]),
    Res =
        case LocalPOC of
            {error, not_found} ->
                %% if the cache returns not found it could be the poc has not yet been initialized
                %% so check if we have a cached local POC key.
                %% These are added when a val HB is submitted by the local node
                %% if such a key exists its an indication the POC may not yet have been initialized
                %% OR the e2qc cache was called before the POC was initialised and it
                %% has cached the {error, not_found} term
                %% so if we have the key then check rocks again,
                %% if still not available then its likely the POC hasnt been initialized
                %% if found then invalidate the e2qc cache
                %% TODO: do the assumptions above still hold true with the val pool generating challenges
                %%       rather than the CG generating challenges ?
                case cached_local_poc_key(OnionKeyHash) of
                    {ok, {_KeyHash, _POCData}} ->
                        %% the submitted key is one of this nodes local keys
                        lager:info("*** ~p is a known key ~p", [OnionKeyHash]),
                        case ?MODULE:local_poc(OnionKeyHash) of
                            {error, _} ->
                                %% clients should retry after a period of time
                                {error, <<"queued_poc">>};
                            {ok, #local_poc{block_hash = BlockHash, target = Challengee, onion = Onion}} ->
                                e2qc:evict(local_pocs, OnionKeyHash),
                                {true, Onion};
                            {ok, #local_poc{block_hash = BlockHash, target = _OtherTarget}} ->
                                e2qc:evict(local_pocs, OnionKeyHash),
                                false;
                            {ok, #local_poc{block_hash = _OtherBlockHash, target = _Target}} ->
                                e2qc:evict(local_pocs, OnionKeyHash),
                                {error, mismatched_block_hash}
                        end;
                    _ ->
                        lager:info("*** ~p is NOT a known key", [OnionKeyHash]),
                        {error, <<"invalid_or_expired_poc">>}
                end;
            {ok, #local_poc{block_hash = BlockHash, target = Challengee, onion = Onion}} ->
                {true, Onion};
            {ok, #local_poc{block_hash = BlockHash, target = _OtherTarget}} ->
                false;
            {ok, #local_poc{block_hash = _OtherBlockHash, target = _Target}} ->
                {error, mismatched_block_hash};
            _ ->
                false
        end,
    lager:info("*** check target result for key ~p: ~p", [OnionKeyHash, Res]),
    Res.

-spec report(
    Report :: {witness, blockchain_poc_witness_v1:poc_witness()} | {receipt, blockchain_poc_receipt_v1:receipt()},
    OnionKeyHash :: binary(),
    Peer :: libp2p_crypto:pubkey_bin(),
    P2PAddr :: libp2p_crypto:peer_id()) -> ok.
report(Report, OnionKeyHash, Peer, P2PAddr) ->
    gen_server:cast(?MODULE, {Report, OnionKeyHash, Peer, P2PAddr}).

-spec local_poc(OnionKeyHash :: binary()) ->
    {ok, local_poc()} | {error, any()}.
local_poc(OnionKeyHash) ->
    case persistent_term:get(?POC_DB_CF, not_found) of
        not_found -> {error, not_found};
        {DB, CF} ->
            case rocksdb:get(DB, CF, OnionKeyHash, []) of
                {ok, Bin} ->
                    [POC] = erlang:binary_to_term(Bin),
                    {ok, POC};
                not_found ->
                    {error, not_found};
                Error ->
                    lager:error("error: ~p", [Error]),
                    Error
            end
    end.

-spec save_poc_key_proposals(libp2p_crypto:pubkey_bin(), key_proposals(), pos_integer()) -> ok.
save_poc_key_proposals(Address, KeyProposals, Height) ->
    %% these are key proposals submitted by *any* validator via their heartbeat
    %% save_poc_key_proposals/3 is called when absorbing a heartbeat
    %% we add the proposed keys to this local cache
    %% and from this cache a random set of keys will be selected as part of
    %% block proposals by validators nodes which are in consensus
    [
        begin
            POCKeyProposalRec = #poc_key_proposal{
                receive_height = Height,
                address = Address,
                key = KeyProposal
            },
            lager:info("caching poc key proposal ~p", [KeyProposal]),
            _ = cache_poc_key_proposal(KeyProposal, POCKeyProposalRec)
        end
        || KeyProposal <- KeyProposals
    ],
    ok.

-spec delete_cached_local_poc_key_proposal(key_proposal()) -> ok.
delete_cached_local_poc_key_proposal(KeyProposal) ->
    true = ets:delete(?KEY_PROPOSALS, KeyProposal),
    ok.

-spec get_random_poc_key_proposals(pos_integer()) -> [{libp2p_crypto:pubkey_bin(), key_proposal()}].
get_random_poc_key_proposals(NumKeys) ->
    Keys = cached_local_poc_key_proposals(),
    ShuffledKeys = blockchain_utils:shuffle(Keys),
    lists:map(
        fun({_Key, #poc_key_proposal{key = Key, address = Address}}) ->
            {Address, Key}
        end, lists:sublist(ShuffledKeys, NumKeys)
    ).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(_Args) ->
    lager:info("starting ~p", [?MODULE]),
    erlang:send_after(500, self(), init),
    {ok, PubKey, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    SelfPubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    DB = miner_poc_mgr_db_owner:db(),
    CF = miner_poc_mgr_db_owner:poc_mgr_cf(),
    ok = persistent_term:put(?POC_DB_CF, {DB, CF}),
    {ok, #state{
        db = DB,
        cf = CF,
        sig_fun = SigFun,
        pub_key = SelfPubKeyBin
    }}.

handle_call({active_pocs}, _From, State = #state{}) ->
    {reply, local_pocs(State), State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast({{witness, Witness}, OnionKeyHash, Peer, _PeerAddr}, State) ->
    handle_witness(Witness, OnionKeyHash, Peer, State);
handle_cast({{receipt, Receipt}, OnionKeyHash, Peer, PeerAddr}, State) ->
    handle_receipt(Receipt, OnionKeyHash, Peer, PeerAddr, State);
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, #state{chain = undefined} = State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), init),
            {noreply, State};
        Chain ->
            ok = blockchain_event:add_handler(self()),
            Ledger = blockchain:ledger(Chain),
            ok = miner_poc:add_stream_handler(blockchain_swarm:tid(), miner_poc_report_handler),
            SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
            {noreply, State#state{
                chain = Chain,
                ledger = Ledger,
                pub_key = SelfPubKeyBin
            }}
    end;
handle_info(init, State) ->
    {noreply, State};
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    {noreply, State#state{chain = NC}};
handle_info({blockchain_event, _Event}, #state{chain = undefined} = State)->
    {noreply, State};
handle_info(
    {blockchain_event, {add_block, BlockHash, Sync, Ledger} = _Event},
    #state{chain = Chain} = State
)->
    CurPOCChallengerType =
        case blockchain:config(?poc_challenger_type, Ledger) of
            {ok, V}  -> V;
            _ -> undefined
        end,
    lager:info("received add block event, sync is ~p, poc_challenge_type is ~p", [Sync, CurPOCChallengerType]),
    State1 = maybe_init_addr_hash(State),
    ok = handle_add_block_event(CurPOCChallengerType, BlockHash, Chain, State1),
    {noreply, State1};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    persistent_term:erase(?POC_DB_CF),
    ok.

%%%===================================================================
%%% breakout functions
%%%===================================================================
-spec handle_add_block_event(
    POCChallengeType :: validator | undefined,
    BlockHash :: binary(),
    Chain :: blockchain:blockchain(),
    State :: state()
) -> ok.
handle_add_block_event(POCChallengeType, BlockHash, Chain, State) when POCChallengeType == validator ->
    case blockchain:get_block(BlockHash, Chain) of
        {ok, Block} ->
            %% save public data on each POC key found in the block to the ledger
            %% that way all validators have access to this public data
            %% however the validator which is running the POC will be the only node
            %% which has the secret
            ok = process_block_pocs(BlockHash, Block, State),
            %% take care of GC
            ok = purge_local_pocs(Block, State),
            BlockHeight = blockchain_block:height(Block),
            Ledger = blockchain:ledger(Chain),
            %% GC local pocs keys every 50 blocks
            case BlockHeight rem 50 == 0 of
                true ->
                    ok = purge_local_poc_keys(BlockHeight, Ledger);
                false ->
                    ok
            end,
            %% GC pocs key proposals every 60 blocks
            case BlockHeight rem 60 == 0 of
                true ->
                    ok = purge_pocs_key_proposals(BlockHeight, Ledger);
                false ->
                    ok
            end;

        _ ->
            %% err what?
            ok
    end;
handle_add_block_event(_POCChallengeType, _BlockHash, _Chain, _State) ->
    ok.

-spec handle_witness(
    Witness :: blockchain_poc_witness_v1:poc_witness(),
    OnionKeyHash :: binary(),
    Address :: libp2p_crypto:pubkey_bin(),
    State :: #state{}
) -> {noreply, state()}.
handle_witness(Witness, OnionKeyHash, Peer, #state{chain = Chain} = State) ->
    lager:info("got witness ~p with onionkeyhash ~p", [Witness, OnionKeyHash]),
    %% Validate the witness is correct
    Ledger = blockchain:ledger(Chain),
    case validate_witness(Witness, Ledger) of
        false ->
            lager:warning("ignoring witness ~p for onionkeyhash ~p. Reason: invalid", [Witness, OnionKeyHash]),
            {noreply, State};
        true ->
            %% get the local POC
            case ?MODULE:local_poc(OnionKeyHash) of
                {error, _} ->
                    lager:warning("ignoring witness ~p for onionkeyhash ~p. Reason: no local_poc", [Witness, OnionKeyHash]),
                    {noreply, State};
                {ok, #local_poc{packet_hashes = PacketHashes, responses = Response0} = POC} ->
                    PacketHash = blockchain_poc_witness_v1:packet_hash(Witness),
                    GatewayWitness = blockchain_poc_witness_v1:gateway(Witness),
                    %% check this is a known layer of the packet
                    case lists:keyfind(PacketHash, 2, PacketHashes) of
                        false ->
                            lager:warning("Saw invalid witness with packet hash ~p and onionkeyhash ~p", [PacketHash, OnionKeyHash]),
                            {noreply, State};
                        {GatewayWitness, PacketHash} ->
                            lager:warning("Saw self-witness from ~p for onionkeyhash ~p", [GatewayWitness, OnionKeyHash]),
                            {noreply, State};
                        _ ->
                            Witnesses = maps:get(PacketHash, Response0, []),
                            PerHopMaxWitnesses = blockchain_utils:poc_per_hop_max_witnesses(Ledger),
                            case erlang:length(Witnesses) >= PerHopMaxWitnesses of
                                true ->
                                    lager:warning("ignoring witness ~p for onionkeyhash ~p. Reason: exceeded per hop max witnesses", [Witness, OnionKeyHash]),
                                    {noreply, State};
                                false ->
                                    %% Don't allow putting duplicate response in the witness list resp
                                    Predicate = fun({_, W}) ->
                                        blockchain_poc_witness_v1:gateway(W) == GatewayWitness
                                    end,
                                    Responses1 =
                                        case lists:any(Predicate, Witnesses) of
                                            false ->
                                                maps:put(
                                                    PacketHash,
                                                    lists:keystore(
                                                        Peer,
                                                        1,
                                                        Witnesses,
                                                        {Peer, Witness}
                                                    ),
                                                    Response0
                                                );
                                            true ->
                                                Response0
                                        end,
                                    UpdatedPOC = POC#local_poc{responses = Responses1},
                                    ok = write_local_poc(UpdatedPOC, State),
                                    {noreply, State}
                            end
                    end
            end
    end.

-spec handle_receipt(
    Receipt :: blockchain_poc_receipt_v1:receipt(),
    OnionKeyHash :: binary(),
    Peer :: libp2p_crypto:pubkey_bin(),
    PeerAddr :: libp2p_crypto:peer_id(),
    State :: #state{}
) -> {noreply, state()}.
handle_receipt(Receipt, OnionKeyHash, Peer, PeerAddr, #state{chain = Chain} = State) ->
    lager:info("got receipt ~p with onionkeyhash ~p", [Receipt, OnionKeyHash]),
    Gateway = blockchain_poc_receipt_v1:gateway(Receipt),
    LayerData = blockchain_poc_receipt_v1:data(Receipt),
    Ledger = blockchain:ledger(Chain),
    case blockchain_poc_receipt_v1:is_valid(Receipt, Ledger) of
        false ->
            lager:warning("ignoring invalid receipt ~p for onionkeyhash", [Receipt, OnionKeyHash]),
            {noreply, State};
        true ->
            %% get the POC data from the cache
            case ?MODULE:local_poc(OnionKeyHash) of
                {error, _} ->
                    lager:warning("ignoring receipt ~p for onionkeyhash ~p. Reason: no local_poc", [Receipt, OnionKeyHash]),
                    {noreply, State};
                {ok, #local_poc{challengees = Challengees, responses = Response0} = POC} ->
                    case lists:keyfind(Gateway, 1, Challengees) of
                        {Gateway, LayerData} ->
                            case maps:get(Gateway, Response0, undefined) of
                                undefined ->
                                    IsFirstChallengee =
                                        case hd(Challengees) of
                                            {Gateway, _} ->
                                                true;
                                            _ ->
                                                false
                                        end,
                                    %% compute address hash and compare to known ones
                                    %% TODO - This needs refactoring, wont work as is
                                    case check_addr_hash(PeerAddr, State) of
                                        true when IsFirstChallengee ->
                                            %% drop whole challenge because we should always be able to get the first hop's receipt
                                            %% TODO: delete the cached POC here?
                                            {noreply, State};
                                        true ->
                                            {noreply, State};
                                        undefined ->
                                            Responses1 = maps:put(
                                                Gateway,
                                                {Peer, Receipt},
                                                Response0
                                            ),
                                            UpdatedPOC = POC#local_poc{responses = Responses1},
                                            ok = write_local_poc(UpdatedPOC, State),
                                            {noreply, State};
                                        PeerHash ->
                                            Responses1 = maps:put(
                                                Gateway,
                                                {Peer,
                                                    blockchain_poc_receipt_v1:addr_hash(
                                                        Receipt,
                                                        PeerHash
                                                    )},
                                                Response0
                                            ),
                                            UpdatedPOC = POC#local_poc{responses = Responses1},
                                            ok = write_local_poc(UpdatedPOC, State),
                                            {noreply, State}
                                    end;
                                _ ->
                                    lager:warning("Already got this receipt ~p for ~p ignoring", [
                                        Receipt,
                                        Gateway
                                    ]),
                                    {noreply, State}
                            end;
                        {Gateway, OtherData} ->
                            lager:warning("Got incorrect layer data ~p from ~p (expected ~p) for onionkeyhash ~p", [
                                Gateway,
                                OtherData,
                                Receipt,
                                OnionKeyHash
                            ]),
                            {noreply, State};
                        false ->
                            lager:warning("Got unexpected receipt from ~p for onionkeyhash", [Gateway, OnionKeyHash]),
                            {noreply, State}
                    end
            end
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
initialize_poc(BlockHash, POCStartHeight, Keys, Vars, #state{chain = Chain, pub_key = Challenger} = State) ->
    Ledger = blockchain:ledger(Chain),
    #{public := OnionCompactKey, secret := {ecc_compact, POCPrivKey}} = Keys,
    POCPubKeyBin = libp2p_crypto:pubkey_to_bin(OnionCompactKey),
    #'ECPrivateKey'{privateKey = PrivKeyBin} = POCPrivKey,
    POCPrivKeyHash = crypto:hash(sha256, PrivKeyBin),
    OnionKeyHash = crypto:hash(sha256, POCPubKeyBin),
    lager:info("*** initializing POC at height ~p for local onion key hash ~p", [POCStartHeight, OnionKeyHash]),
    Entropy = <<OnionKeyHash/binary, BlockHash/binary>>,
    lager:info("*** entropy constructed using onionkeyhash ~p and blockhash ~p", [OnionKeyHash, BlockHash]),
    ZoneRandState = blockchain_utils:rand_state(Entropy),
    InitTargetRandState = blockchain_utils:rand_state(POCPrivKeyHash),
    lager:info("*** ZoneRandState ~p", [ZoneRandState]),
    lager:info("*** InitTargetRandState ~p", [InitTargetRandState]),
    case blockchain_poc_target_v4:target(Challenger, InitTargetRandState, ZoneRandState, Ledger, Vars) of
        {error, Reason}->
            lager:info("*** failed to find a target, reason ~p", [Reason]),
            noop;
        {ok, {TargetPubkeybin, TargetRandState}}->
            lager:info("*** found target ~p", [TargetPubkeybin]),
            {ok, LastChallenge} = blockchain_ledger_v1:current_height(Ledger),
            {ok, B} = blockchain:get_block(LastChallenge, Chain),
            Time = blockchain_block:time(B),
            Path = blockchain_poc_path_v4:build(TargetPubkeybin, TargetRandState, Ledger, Time, Vars),
            lager:info("path created ~p", [Path]),
            N = erlang:length(Path),
            [<<IV:16/integer-unsigned-little, _/binary>> | LayerData] = blockchain_txn_poc_receipts_v2:create_secret_hash(
                Entropy,
                N + 1
            ),
            OnionList = lists:zip([libp2p_crypto:bin_to_pubkey(P) || P <- Path], LayerData),
            {Onion, Layers} = blockchain_poc_packet_v2:build(Keys, IV, OnionList),
            [_|LayerHashes] = [crypto:hash(sha256, L) || L <- Layers],
            Challengees = lists:zip(Path, LayerData),
            PacketHashes = lists:zip(Path, LayerHashes),
            Secret = libp2p_crypto:keys_to_bin(Keys),
            %% save the POC data to our local cache
            LocalPOC = #local_poc{
                onion_key_hash = OnionKeyHash,
                block_hash = BlockHash,
                target = TargetPubkeybin,
                onion = Onion,
                secret = Secret,
                challengees = Challengees,
                packet_hashes = PacketHashes,
                keys = Keys,
                start_height = POCStartHeight
            },
            ok = write_local_poc(LocalPOC, State),
            lager:info("starting poc for challengeraddr ~p, onionhash ~p", [Challenger, OnionKeyHash]),
            ok
    end.

-spec process_block_pocs(
    BlockHash :: blockchain_block:hash(),
    Block :: blockchain_block:block(),
    State :: state()
) -> ok.
process_block_pocs(
    BlockHash,
    Block,
    #state{chain = Chain} = State
) ->
    Ledger = blockchain:ledger(Chain),
    BlockHeight = blockchain_block:height(Block),
    %% get the ephemeral keys from the block
    %% these will be a prop with tuples as {MemberPosInCG, PocKeyHash}
    BlockPocEphemeralKeys = blockchain_block_v1:poc_keys(Block),
    [
        begin
            %% the published key is a hash of the public key, aka the onion key hash
            %% use this to check our local cache containing the keys of POCs owned by this validator
            %% if it is one of this local validators POCs, then kick it off
            case cached_local_poc_key(OnionKeyHash) of
                {ok, {_KeyHash, #poc_local_key_data{keys = Keys}}} ->
                    lager:info("found local poc key, starting a poc for ~p", [OnionKeyHash]),
                    %% its a locally owned POC key, so kick off a new POC
                    Vars = blockchain_utils:vars_binary_keys_to_atoms(maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))),
                    spawn_link(fun() -> initialize_poc(BlockHash, BlockHeight, Keys, Vars, State) end);
                _ ->
                    lager:info("failed to find local poc key for ~p", [OnionKeyHash]),
                    noop
            end,
            %% GC the block key from the key proposals cache
            _ = delete_cached_local_poc_key_proposal(OnionKeyHash)
        end
        || {_CGPos, OnionKeyHash} <- BlockPocEphemeralKeys
    ],
    ok.

-spec purge_local_pocs(
    Block :: blockchain_block:block(),
    State :: state()
) -> ok.
purge_local_pocs(
    Block,
    #state{chain = Chain, pub_key = SelfPubKeyBin, sig_fun = SigFun} = State
) ->
    %% iterate over the local POCs in our rocksdb
    %% end and clean up any which have exceeded their life span
    %% these are active POCs which were initiated by this node
    %% and the data is known only to this node
    Ledger = blockchain:ledger(Chain),
    Timeout =
        case blockchain:config(?poc_timeout, Ledger) of
            {ok, N} -> N;
            _ -> ?POC_TIMEOUT
        end,
    BlockHeight = blockchain_block:height(Block),
    LocalPOCs = local_pocs(State),
    lists:foreach(
        fun([#local_poc{start_height = POCStartHeight, onion_key_hash = OnionKeyHash} = POC]) ->
            case (BlockHeight - POCStartHeight) > Timeout of
                true ->
                    lager:info("*** purging local poc with key ~p", [OnionKeyHash]),
                    %% this POC's time is up, submit receipts we have received
                    ok = submit_receipts(POC, SelfPubKeyBin, SigFun, Chain),
                    %% as receipts have been submitted, we can delete the local poc from the db
                    %% the public poc data will remain until at least the receipt txn is absorbed
                    _ = delete_local_poc(OnionKeyHash, State);
                _ ->
                    lager:info("*** not purging local poc with key ~p.  BlockHeight: ~p, POCStartHeight: ~p", [OnionKeyHash, BlockHeight, POCStartHeight]),
                    ok
            end
        end,
        LocalPOCs
    ),
    ok.

-spec purge_local_poc_keys(
    BlockHeight :: pos_integer(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> ok.
purge_local_poc_keys(
    BlockHeight,
    Ledger
) ->
    %% iterate over the poc keys in our ets cache
    %% and purge any which are deemed to be passed due
    %% these keys are generated by *this* node
    %% as part of its heartbeat submission
    %% and added to the poc_mgr cache
    %% each new block check if each mined key
    %% for that block is one of our own
    %% if it is then we initiate a new local POC
    %% the keys are purged periodically
    Timeout =
        case blockchain:config(?poc_timeout, Ledger) of
            {ok, N} -> N;
            _ -> ?POC_TIMEOUT
        end,
    %% iterate over the cached POC keys, delete any which are beyond the lifespan of when the active POC would have ended
    CachedPOCKeys = cached_local_poc_keys(),
    lists:foreach(
        fun({Key, #poc_local_key_data{receive_height = ReceiveHeight}}) ->
            case (BlockHeight - ReceiveHeight) > Timeout of
                true ->
                    %% the lifespan of any POC for this key has passed, we can GC
                    ok = delete_cached_local_poc_key(Key);
                _ ->
                    ok
            end
        end,
        CachedPOCKeys
    ),
    ok.

-spec purge_pocs_key_proposals(
    BlockHeight :: pos_integer(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> ok.
purge_pocs_key_proposals(
    BlockHeight,
    Ledger
) ->
    %% iterate over the poc key proposals in our ets cache
    %% and purge any which are deemed to be passed due
    %% these proposed keys are those generated by any validator
    %% and cached on this node when absorbing validator heartbeats
    %% when blocks are proposed, a random subset of keys
    %% from this cache will be selected and included
    %% in the local block proposal ( assuming the node is in the CG )
    %% one or more of these proposed keys *may* make it into the block
    %% in order to prevent an unbounded cache we will GC
    %% keys in this cache periodically
    %% NOTE: a key will also be removed from the cache should it make it into a block
    Timeout =
        case blockchain:config(?poc_validator_ephemeral_key_timeout, Ledger) of
            {ok, N} -> N;
            _ -> 200
        end,
    CachedPOCKeyProposals = cached_local_poc_key_proposals(),
    lists:foreach(
        fun({Key, #poc_key_proposal{receive_height = ReceiveHeight}}) ->
            case (BlockHeight - ReceiveHeight) > Timeout of
                true ->
                    %% the lifespan of any POC for this key has passed, we can GC
                    ok = delete_cached_local_poc_key_proposal(Key);
                _ ->
                    ok
            end
        end,
        CachedPOCKeyProposals
    ),
    ok.

-spec submit_receipts(local_poc(), libp2p_crypto:pubkey_bin(), libp2p_crypto:sig_fun(), blockchain:blockchain()) -> ok.
submit_receipts(
    #local_poc{
        onion_key_hash = OnionKeyHash,
        responses = Responses0,
        secret = Secret,
        packet_hashes = LayerHashes,
        block_hash = BlockHash
    } = _Data,
    Challenger,
    SigFun,
    Chain
) ->
    Path1 = lists:foldl(
        fun({Challengee, LayerHash}, Acc) ->
            {Address, Receipt} = maps:get(Challengee, Responses0, {make_ref(), undefined}),
            %% get any witnesses not from the same p2p address and also ignore challengee as a witness (self-witness)
            Witnesses = [
                W
                || {A, W} <- maps:get(LayerHash, Responses0, []), A /= Address, A /= Challengee
            ],
            E = blockchain_poc_path_element_v1:new(Challengee, Receipt, Witnesses),
            [E | Acc]
        end,
        [],
        LayerHashes
    ),
    Txn0 =
        case blockchain:config(?poc_version, blockchain:ledger(Chain)) of
            {ok, PoCVersion} when PoCVersion >= 10 ->
                blockchain_txn_poc_receipts_v2:new(
                    Challenger,
                    Secret,
                    OnionKeyHash,
                    lists:reverse(Path1),
                    BlockHash
                );
            _ ->
                %% hmm we shouldnt really hit here as this all started with poc version 10
                noop
        end,
    Txn1 = blockchain_txn:sign(Txn0, SigFun),
    lager:info("submitting blockchain_txn_poc_receipts_v2 for onion key hash ~p: ~p", [OnionKeyHash, Txn0]),
    case miner_consensus_mgr:in_consensus() of
        false ->
            lager:info("node is not in consensus", []),
            ok = blockchain_txn_mgr:submit(Txn1, fun(_Result) -> noop end);
        true ->
            lager:info("node is in consensus", []),
            _ = miner_hbbft_sidecar:submit(Txn1)
    end,

    ok.

-spec cache_poc_key(poc_key(), cached_local_poc_local_key_data()) -> true.
cache_poc_key(ID, Keys) ->
    true = ets:insert(?KEYS, {ID, Keys}).

-spec cached_local_poc_keys() -> [cached_local_poc_key_type()].
cached_local_poc_keys() ->
    ets:tab2list(?KEYS).

-spec delete_cached_local_poc_key(poc_key()) -> ok.
delete_cached_local_poc_key(Key) ->
    true = ets:delete(?KEYS, Key),
    ok.

-spec cache_poc_key_proposal(key_proposal(), cached_key_proposal()) -> true.
cache_poc_key_proposal(KeyProposal, Rec) ->
    true = ets:insert(?KEY_PROPOSALS, {KeyProposal, Rec}).

-spec cached_local_poc_key_proposals() -> [cached_key_proposal()].
cached_local_poc_key_proposals() ->
    ets:tab2list(?KEY_PROPOSALS).

-spec validate_witness(blockchain_poc_witness_v1:witness(), blockchain_ledger_v1:ledger()) ->
    boolean().
validate_witness(Witness, Ledger) ->
    Gateway = blockchain_poc_witness_v1:gateway(Witness),
    %% TODO this should be against the ledger at the time the receipt was mined
    case blockchain_ledger_v1:find_gateway_info(Gateway, Ledger) of
        {error, _Reason} ->
            lager:warning("failed to get witness ~p info ~p", [Gateway, _Reason]),
            false;
        {ok, GwInfo} ->
            case blockchain_ledger_gateway_v2:location(GwInfo) of
                undefined ->
                    lager:warning("ignoring witness ~p location undefined", [Gateway]),
                    false;
                _ ->
                    blockchain_poc_witness_v1:is_valid(Witness, Ledger)
            end
    end.

check_addr_hash(_PeerAddr, #state{addr_hash_filter = undefined}) ->
    undefined;
check_addr_hash(PeerAddr, #state{
    addr_hash_filter = #addr_hash_filter{byte_size = Size, salt = Hash, bloom = Bloom}
}) ->
    case multiaddr:protocols(PeerAddr) of
        [{"ip4", Address}, {_, _}] ->
            {ok, Addr} = inet:parse_ipv4_address(Address),
            Val = binary:part(
                enacl:pwhash(
                    list_to_binary(tuple_to_list(Addr)),
                    binary:part(Hash, {0, enacl:pwhash_SALTBYTES()})
                ),
                {0, Size}
            ),
            case bloom:check_and_set(Bloom, Val) of
                true ->
                    true;
                false ->
                    Val
            end;
        _ ->
            undefined
    end.

-spec maybe_init_addr_hash(#state{}) -> #state{}.
maybe_init_addr_hash(#state{chain = undefined} = State) ->
    %% no chain
    State;
maybe_init_addr_hash(#state{chain = Chain, addr_hash_filter = undefined} = State) ->
    %% check if we have the block we need
    Ledger = blockchain:ledger(Chain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, Height} = blockchain:height(Chain),
                    StartHeight = max(Height - (Height rem Interval), 1),
                    %% check if we have this block
                    case blockchain:get_block(StartHeight, Chain) of
                        {ok, Block} ->
                            Hash = blockchain_block:hash_block(Block),
                            %% ok, now we can build the filter
                            Gateways = blockchain_ledger_v1:gateway_count(Ledger),
                            {ok, Bloom} = bloom:new_optimal(Gateways, ?ADDR_HASH_FP_RATE),
                            sync_filter(Block, Bloom, Chain),
                            State#state{
                                addr_hash_filter = #addr_hash_filter{
                                    start = StartHeight,
                                    height = Height,
                                    byte_size = Bytes,
                                    salt = Hash,
                                    bloom = Bloom
                                }
                            };
                        _ ->
                            State
                    end;
                _ ->
                    State
            end;
        _ ->
            State
    end;
maybe_init_addr_hash(
    #state{
        chain = Chain,
        addr_hash_filter = #addr_hash_filter{
            start = StartHeight,
            height = Height,
            byte_size = Bytes,
            salt = Hash,
            bloom = Bloom
        }
    } = State
) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, CurHeight} = blockchain:height(Chain),
                    case max(Height - (Height rem Interval), 1) of
                        StartHeight ->
                            case CurHeight of
                                Height ->
                                    %% ok, everything lines up
                                    State;
                                _ ->
                                    case blockchain:get_block(Height + 1, Chain) of
                                        {ok, Block} ->
                                            sync_filter(Block, Bloom, Chain),
                                            State#state{
                                                addr_hash_filter = #addr_hash_filter{
                                                    start = StartHeight,
                                                    height = CurHeight,
                                                    byte_size = Bytes,
                                                    salt = Hash,
                                                    bloom = Bloom
                                                }
                                            };
                                        _ ->
                                            State
                                    end
                            end;
                        _NewStart ->
                            %% filter is stale
                            maybe_init_addr_hash(State#state{addr_hash_filter = undefined})
                    end;
                _ ->
                    State
            end;
        _ ->
            State#state{addr_hash_filter = undefined}
    end.

sync_filter(StopBlock, Bloom, Blockchain) ->
    blockchain:fold_chain(
        fun(Blk, _) ->
            blockchain_utils:find_txn(Blk, fun(T) ->
                case blockchain_txn:type(T) == blockchain_txn_poc_receipts_v2 of
                    true ->
                        %% abuse side effects here for PERFORMANCE
                        [update_addr_hash(Bloom, E) || E <- blockchain_txn_poc_receipts_v2:path(T)];
                    false ->
                        ok
                end,
                false
            end),
            case Blk == StopBlock of
                true ->
                    return;
                false ->
                    continue
            end
        end,
        any,
        element(2, blockchain:head_block(Blockchain)),
        Blockchain
    ).

-spec update_addr_hash(
    Bloom :: bloom_nif:bloom(),
    Element :: blockchain_poc_path_element_v1:poc_element()
) -> ok.
update_addr_hash(Bloom, Element) ->
    case blockchain_poc_path_element_v1:receipt(Element) of
        undefined ->
            ok;
        Receipt ->
            case blockchain_poc_receipt_v1:addr_hash(Receipt) of
                undefined ->
                    ok;
                Hash ->
                    bloom:set(Bloom, Hash)
            end
    end.

%% ------------------------------------------------------------------
%% DB functions
%% ------------------------------------------------------------------

%%-spec append_local_poc(NewLocalPOC :: local_poc(),
%%                       State :: state()) -> ok | {error, any()}.
%%append_local_poc(#local_poc{onion_key_hash=OnionKeyHash} = NewLocalPOC, #state{db=DB, cf=CF}=State) ->
%%    case ?MODULE:local_poc(OnionKeyHash) of
%%        {ok, SavedLocalPOCs} ->
%%            %% check we're not writing something we already have
%%            case lists:member(NewLocalPOC, SavedLocalPOCs) of
%%                true ->
%%                    ok;
%%                false ->
%%                    ToInsert = erlang:term_to_binary([NewLocalPOC | SavedLocalPOCs]),
%%                    rocksdb:put(DB, CF, OnionKeyHash, ToInsert, [])
%%            end;
%%        {error, not_found} ->
%%            ToInsert = erlang:term_to_binary([NewLocalPOC]),
%%            rocksdb:put(DB, CF, OnionKeyHash, ToInsert, []);
%%        {error, _}=E ->
%%            E
%%    end.

local_pocs(#state{db=DB, cf=CF}) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    local_pocs(Itr, rocksdb:iterator_move(Itr, first), []).

local_pocs(Itr, {error, invalid_iterator}, Acc) ->
    catch rocksdb:iterator_close(Itr),
    Acc;
local_pocs(Itr, {ok, _, LocalPOCBin}, Acc) ->
    local_pocs(Itr, rocksdb:iterator_move(Itr, next), [binary_to_term(LocalPOCBin)|Acc]).

-spec write_local_poc(  LocalPOC ::local_poc(),
                        State :: state()) -> ok.
write_local_poc(#local_poc{onion_key_hash=OnionKeyHash} = LocalPOC, #state{db=DB, cf=CF}) ->
    ToInsert = erlang:term_to_binary([LocalPOC]),
    rocksdb:put(DB, CF, OnionKeyHash, ToInsert, []).

-spec delete_local_poc( OnionKeyHash ::binary(),
                        State :: state()) -> ok.
delete_local_poc(OnionKeyHash, #state{db=DB, cf=CF}) ->
    rocksdb:delete(DB, CF, OnionKeyHash, []).
