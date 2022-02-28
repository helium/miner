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
                            %% we need to construct and submit a heartbeat txn
                            {ok, CBMod} = blockchain_ledger_v1:config(?predicate_callback_mod, Ledger),
                            {ok, Callback} = blockchain_ledger_v1:config(?predicate_callback_fun, Ledger),
                            {EmpKeys, EmpKeyHashes} = generate_poc_keys(Ledger),
                            lager:debug("HB poc ephemeral keys ~p", [EmpKeys]),
                            ok = miner_poc_mgr:save_local_poc_keys(Height, EmpKeys),
                            UnsignedTxn =
                                blockchain_txn_validator_heartbeat_v1:new(Address, Height, CBMod:Callback(), EmpKeyHashes),
                            Txn = blockchain_txn_validator_heartbeat_v1:sign(UnsignedTxn, SigFun),
                            lager:info("submitting txn ~p for val ~p ~p ~p", [Txn, Val, N, HBInterval]),
                            Self = self(),
                            blockchain_worker:submit_txn(Txn, fun(Res) -> Self ! {sub, Res} end),
                            {noreply, State#state{txn_status = waiting}};
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
    case blockchain:config(?poc_challenger_type, Ledger) of
        {ok, validator} ->
            %% if a val is in the ignore list then dont generate poc keys for it
            %% TODO: this is a temp hack.  remove when testing finished
            IgnoreVals = application:get_env(sibyl, validator_ignore_list, []),
            SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
            case not lists:member(SelfPubKeyBin, IgnoreVals) of
                true ->
                    %% generate a set of ephemeral keys for POC usage
                    EphemeralKeyCount =
                        case blockchain:config(?poc_validator_ephemeral_key_count, Ledger) of
                            {ok, N} -> N;
                            _ -> 1
                        end,
                    lager:debug("heartbeat ephemeral key count ~p", [EphemeralKeyCount]),
                    generate_ephemeral_keys(EphemeralKeyCount);
                false ->
                    {[], []}
            end;
        _ ->
            {[], []}

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
