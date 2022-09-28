-module(miner_val_heartbeat).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(start_wait, 5).

-record(state,
        {
         address :: libp2p_crypto:address(),
         sigfun :: libp2p_crypto:sig_fun(),
         txn_status = ready :: ready | waiting,
         txn_wait = ?start_wait :: non_neg_integer(),
         chain :: undefined | blockchain:blockchain()
        }).

-ifdef(TEST).
-define(BYPASS_IP_CHECK,true).
-else.
-define(BYPASS_IP_CHECK,false).
-endif.


%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, Address0, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    Address = libp2p_crypto:pubkey_to_bin(Address0),
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), chain_check),
            {ok, #state{address = Address,
                        sigfun = SigFun}};
        Chain ->
            ok = blockchain_event:add_handler(self()),
            {ok, #state{address = Address,
                        sigfun = SigFun,
                        chain = Chain}}
    end.

handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, _Hash, _Sync, _Ledger}},
            #state{txn_status = waiting, txn_wait = Wait} = State) ->
    case Wait of
        1 ->
            {noreply, State#state{txn_status = ready, txn_wait = ?start_wait}};
        N ->
            {noreply, State#state{txn_wait = N - 1}}
    end;
handle_info({blockchain_event, {add_block, Hash, Sync, _Ledger}},
            #state{address = Address, sigfun = SigFun} = State) ->
    Ledger = blockchain:ledger(State#state.chain),
    case blockchain:config(?validator_version, Ledger) of
        {ok, V} when V >= 1 ->
            {ok, HBInterval} = blockchain:config(?validator_liveness_interval, Ledger),
            Now = erlang:system_time(seconds),
            {ok, Block} = blockchain:get_block(Hash, State#state.chain),
            Height = blockchain_block:height(Block),
            TimeAgo = Now - blockchain_block:time(Block),
            %% heartbeat server needs to be able to run on an unstaked validator
            case blockchain_ledger_v1:get_validator(Address, Ledger) of
                {ok, Val} ->
                    lager:debug("getting validator for address ~p got ~p", [Address, Val]),
                    case blockchain_ledger_validator_v1:last_heartbeat(Val) of
                        N when (N + HBInterval) =< Height
                               andalso ((not Sync) orelse TimeAgo =< (60 * 30)) ->
                            %% it is time to heartbeat, check for a public listening address
                            SwarmTID = blockchain_swarm:tid(),
                            PeerBook = libp2p_swarm:peerbook(SwarmTID),
                            {ok, Peer} = libp2p_peerbook:get(PeerBook, blockchain_swarm:pubkey_bin()),
                            ListenAddresses = libp2p_peer:listen_addrs(Peer),
                            case ?BYPASS_IP_CHECK orelse lists:any(fun libp2p_transport_tcp:is_public/1, ListenAddresses) of
                                true ->
                                    %% we need to construct and submit a heartbeat txn
                                    {ok, CBMod} = blockchain_ledger_v1:config(?predicate_callback_mod, Ledger),
                                    {ok, Callback} = blockchain_ledger_v1:config(?predicate_callback_fun, Ledger),
                                    %% generate a set of ephemeral keys to represent POC
                                    %% key proposals for this heartbeat
                                    %% hashes of the public keys are included in the HB
                                    %% public and private keys are cached locally
                                    {EmpKeys, EmpKeyHashes} = generate_poc_keys(Ledger),
                                    lager:debug("HB poc ephemeral keys ~p", [EmpKeys]),
                                    ok = miner_poc_mgr:save_local_poc_keys(Height, EmpKeys),
                                    %% include any inactive GWs which have since come active
                                    %% activity here is determined by subscribing to the
                                    %% poc stream
                                    ReactivatedGWs = reactivated_gws(Ledger),
                                    UnsignedTxn =
                                        blockchain_txn_validator_heartbeat_v1:new(Address, Height, CBMod:Callback(), EmpKeyHashes, ReactivatedGWs),
                                    Txn = blockchain_txn_validator_heartbeat_v1:sign(UnsignedTxn, SigFun),
                                    lager:info("submitting txn ~p for val ~p ~p ~p", [Txn, Val, N, HBInterval]),
                                    Self = self(),
                                    blockchain_worker:submit_txn(Txn, fun(Res) -> Self ! {sub, Res} end),
                                    {noreply, State#state{txn_status = waiting}};
                                false ->
                                    lager:warning("skipping heartbeat, validator has no public listen address in peerbook: ~p",
                                        [ListenAddresses]),
                                    {noreply, State}
                            end;
                        _ -> {noreply, State}
                    end;
                {error, not_found} ->
                    lager:debug("getting validator for address ~p not found", [Address]),
                    {noreply, State}
            end;
        _ ->
            {noreply, State}
    end;
%% logically it doesn't matter what the result is, we either need to start actively waiting or
%% trying again
handle_info({sub, Res}, State) ->
    lager:info("txn result ~p", [Res]),
    {noreply, State#state{txn_status = ready, txn_wait = 10}};
handle_info({blockchain_event, _}, State) ->
    {noreply, State};
handle_info(chain_check, State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), chain_check),
            {noreply, State};
        Chain ->
            ok = blockchain_event:add_handler(self()),
            {noreply, State#state{chain = Chain}}
    end;
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
-spec generate_poc_keys(blockchain:ledger()) ->
    {[#{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}], [binary()]}.
generate_poc_keys(Ledger) ->
    case blockchain_ledger_v1:config(?poc_challenger_type, Ledger) of
        {ok, validator} ->
            %% if a val is in the ignore list then dont generate poc keys for it
            %% TODO: this is a temp hack.  remove when testing finished
            IgnoreVals = application:get_env(sibyl, validator_ignore_list, []),
            SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
            case not lists:member(SelfPubKeyBin, IgnoreVals) of
                true ->
                    %% generate a set of ephemeral keys for POC usage
                    %% count is based on the num of active validators and the
                    %% target challenge rate
                    %% we also have to consider that key proposals are
                    %% submitted by validators as part of their heartbeats
                    %% which are only submitted periodically
                    %% so we need to ensure we have sufficient count of
                    %% key proposals submitted per HB
                    %% to help with this we reduce the number of val count
                    %% by 20% so that we have surplus keys being submitted
                    NumProposals = proposal_length(Ledger),
                    generate_ephemeral_keys(NumProposals);
                false ->
                    {[], []}
            end;
        _ ->
            {[], []}

    end.

-spec proposal_length(blockchain:ledger()) -> non_neg_integer().
proposal_length(Ledger) ->
    %% generate the size for a set of ephemeral keys for POC usage. the count is based on the num of
    %% active validators and the target challenge rate. we also have to consider that key proposals
    %% are submitted by validators as part of their heartbeats which are only submitted periodically
    %% so we need to ensure we have sufficient count of key proposals submitted per HB. to help with
    %% this we reduce the number of val count by 20% so that we have surplus keys being submitted
    case blockchain_ledger_v1:validator_count(Ledger) of
        {ok, NumVals} when NumVals > 0 ->
            {ok, ChallengeRate} = blockchain_ledger_v1:config(?poc_challenge_rate, Ledger),
            {ok, ValCtScale} = blockchain_ledger_v1:config(?poc_validator_ct_scale, Ledger),
            {ok, HBInterval} = blockchain_ledger_v1:config(?validator_liveness_interval, Ledger),
            round((ChallengeRate / (NumVals * ValCtScale)) * HBInterval);
        _ ->
            0
    end.


-spec generate_ephemeral_keys(pos_integer()) -> {[#{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}], [binary()]}.
generate_ephemeral_keys(NumKeys) ->
    lists:foldl(
        fun(_N, {AccKeys, AccHashes})->
            Keys = libp2p_crypto:generate_keys(ecc_compact),
            #{public := OnionCompactKey} = Keys,
            OnionHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
            {[Keys | AccKeys], [OnionHash | AccHashes]}
        end,
        {[], []}, lists:seq(1, NumKeys)).

reactivated_gws(Ledger)->
    case
        {blockchain_ledger_v1:config(?poc_challenger_type, Ledger),
            blockchain_ledger_v1:config(?poc_activity_filter_enabled, Ledger)} of
        {{ok, oracle}, _} ->
            [];
        {_, {ok, true}} ->
            ReactivatedGWs = sibyl_poc_mgr:cached_reactivated_gws(),
            %% HBs limit the size of this list, so truncate if necessary
            %% and remove from the cache those included
            {ok, ReactListMaxSize} = blockchain_ledger_v1:config(?validator_hb_reactivation_limit, Ledger),
            ReactivatedGWs1 = lists:sublist(ReactivatedGWs, ReactListMaxSize),
            _ = sibyl_poc_mgr:delete_reactivated_gws(ReactivatedGWs1),
            ReactivatedGWs1;
        _ ->
            []
    end.
