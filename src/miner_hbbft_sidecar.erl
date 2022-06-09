-module(miner_hbbft_sidecar).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

% API
-export([
         start_link/0,
         submit/1,
         set_group/1,
         new_round/2,
         prefilter_round/2,
         handle_txn/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-ifdef(TEST).
-define(SlowTxns, #{blockchain_txn_poc_receipts_v1 => 10000,
                    blockchain_txn_poc_receipts_v2 => 10000,
                    blockchain_txn_consensus_group_v1 => 30000}).
-else.
-define(SlowTxns, #{blockchain_txn_poc_receipts_v1 => 75,
                    blockchain_txn_poc_receipts_v2 => 75,
                    blockchain_txn_consensus_group_v1 => 30000}).
-endif.

%% txns that do not appear naturally
-define(InvalidTxns, [blockchain_txn_reward_v1, blockchain_txn_reward_v2]).

-define(SUBMITTED_TXNS, submitted_txns).
-define(VALID_TXNS, valid_txns).
-define(INVALID_TXNS, invalid_txns).
-define(TIMEDOUT_TXNS, timedout_txns).
-define(VALIDATION_METRICS, [?SUBMITTED_TXNS, ?VALID_TXNS, ?INVALID_TXNS, ?TIMEDOUT_TXNS]).

-record(validation,
        {
         timer :: reference(),
         monitor :: reference(),
         pid :: pid(),
         txn :: blockchain_txn:txn(),
         from :: {pid(), term()}, % gen server doesn't export this?!?!
         height :: non_neg_integer()
        }).

-record(state,
        {
         chain :: undefined | blockchain:blockchain(),
         group :: undefined | pid(),
         queue = [] :: [{{pid(), term()}, blockchain_txn:txn(), non_neg_integer()}],
         validations = #{} :: #{reference() => #validation{}}
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], [{hibernate_after, 5000}]).

-spec submit(Txn :: term()) ->
    {
        Result :: ok | {error, _},
        Height :: non_neg_integer()
    }.
submit(Txn) ->
    lager:debug("submitting txn"),
    gen_server:call(?SERVER, {submit, Txn}, infinity).

set_group(Group) ->
    lager:debug("setting group to ~p", [Group]),
    gen_server:call(?SERVER, {set_group, Group}, infinity).

-spec new_round([binary()], [binary()]) -> [binary()].
new_round(Buf, BinTxns) ->
    gen_server:call(?SERVER, {new_round, Buf, BinTxns}, infinity).

-spec prefilter_round([binary()], blockchain_txn:txns()) -> [binary()].
prefilter_round(Buf, Txns) ->
    gen_server:call(?SERVER, {prefilter_round, Buf, Txns}, infinity).

handle_txn(submit = RequestType, Txn) ->
    lager:debug("handling txn with request type ~p", [RequestType]),
    gen_server:call(?SERVER, {submit, Txn}, infinity);
handle_txn(update = RequestType, Txn) ->
    lager:debug("handling txn with request type ~p", [RequestType]),
    gen_server:call(?SERVER, {query_txn, Txn}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    init(#state{});
init(State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), chain_check),
            {ok, State#state{}};
        Chain ->
            Ledger0 = blockchain:ledger(Chain),
            Ledger = blockchain_ledger_v1:new_context(Ledger0),
            Chain1 = blockchain:ledger(Ledger, Chain),
            {ok, State#state{chain = Chain1}}
    end.

handle_call({set_group, Group}, _From, #state{group = OldGroup} = State) ->
    lager:debug("setting group to ~p", [Group]),
    case {OldGroup, Group} of
        {undefined, undefined} ->
            ok;
        {P1, P2} when is_pid(P1) andalso is_pid(P2)  ->
            ok;
        {undefined, P} when is_pid(P) ->
            ok = libp2p_swarm:add_stream_handler(blockchain_swarm:tid(), ?TX_PROTOCOL_V3,
                {libp2p_framed_stream, server,
                    [blockchain_txn_handler, ?TX_PROTOCOL_V3, self(),
                        fun(ReqType, Txn) -> ?MODULE:handle_txn(ReqType, Txn) end]}),
            ok = libp2p_swarm:add_stream_handler(blockchain_swarm:tid(), ?TX_PROTOCOL_V2,
                                                 {libp2p_framed_stream, server,
                                                  [blockchain_txn_handler, ?TX_PROTOCOL_V2, self(),
                                                   fun(T) -> ?MODULE:submit(T) end]}),
            ok = libp2p_swarm:add_stream_handler(blockchain_swarm:tid(), ?TX_PROTOCOL_V1,
                                                 {libp2p_framed_stream, server,
                                                  [blockchain_txn_handler, ?TX_PROTOCOL_V1, self(),
                                                   fun(T) -> ?MODULE:submit(T) end]});
        {P, undefined} when is_pid(P) ->
            libp2p_swarm:remove_stream_handler(blockchain_swarm:tid(), ?TX_PROTOCOL_V2),
            libp2p_swarm:remove_stream_handler(blockchain_swarm:tid(), ?TX_PROTOCOL_V1)
    end,
    {reply, ok, State#state{group = Group}};
handle_call({submit, _}, _From, #state{chain = undefined} = State) ->
    lager:debug("submission with no chain set"),
    {reply, {{error, no_chain}, 0}, State};
handle_call({submit, _}, _From, #state{group = undefined, chain = Chain} = State) ->
    lager:debug("submission with no group set"),
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
    {reply, {{error, no_group}, Height}, State};
handle_call({submit, Txn}, From,
            #state{chain = Chain,
                   group = Group,
                   queue = Queue,
                   validations = Validations} = State) ->
    Type = blockchain_txn:type(Txn),
    lager:debug("got submission of txn: ~s", [blockchain_txn:print(Txn)]),
    Ledger = blockchain:ledger(Chain),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% if challenger vals are enabled dont submit poc_receipt txns
    ChallType = get_config(?poc_challenger_type, undefined, Ledger),
    case lists:member(Type, ?InvalidTxns) orelse
            (ChallType =:= validator andalso Type =:= blockchain_txn_poc_request_v1) of
        true ->
            {reply, {{error, invalid_txn}, Height}, State};
        false ->
            case oversized_txn(Txn, Ledger) of
                true ->
                    {reply, {{error, oversized_txn}, Height}, State};
                false ->
                    case maps:find(Type, ?SlowTxns) of
                        {ok, Timeout} ->
                            Limit = application:get_env(miner, sidecar_parallelism_limit, 3),
                            case maps:size(Validations) of
                                N when N >= Limit ->
                                    Queue1 = Queue ++ [{From, Txn, Height}],
                                    {noreply, State#state{queue = Queue1}};
                                _ ->
                                    ok = update_validation_metric(?SUBMITTED_TXNS, Type),
                                    {Attempt, V} = start_validation(Txn, Height, From, Timeout, Chain),
                                    {noreply, State#state{validations = Validations#{Attempt => V}}}
                            end;
                        error ->
                            case blockchain_txn:is_valid(Txn, Chain) of
                                ok ->
                                    case blockchain_txn:absorb(Txn, Chain) of
                                        ok ->
                                            spawn(fun() ->
                                                        %% this will now return {ok, Position, Length}
                                                        %% or {error, full} which we could feed back to the caller using gen_server:reply() on the From
                                                        {ok, _PosInQueue, _QueueLen, Height} = Res = libp2p_group_relcast:handle_command(Group, {txn, Txn}),
                                                        gen_server:reply(From, Res)
                                                  end),
                                            {noreply, State};
                                        Error ->
                                            lager:warning("speculative absorb failed for ~s, error: ~p", [blockchain_txn:print(Txn), Error]),
                                            {reply, {Error, Height}, State}
                                    end;
                                Error ->
                                    write_txn("failed", Height, Txn),
                                    lager:debug("is_valid failed for ~s, error: ~p", [blockchain_txn:print(Txn), Error]),
                                    {reply, {Error, Height}, State}
                            end
                    end
            end
    end;
handle_call({new_round, _Buf, _RemoveTxns}, _From, #state{chain = undefined} = State) ->
    {reply, [], State};
handle_call({new_round, Buf, RemoveTxns}, _From, #state{chain = Chain} = State) ->
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:reset_context(Ledger),
    Buf1 = Buf -- RemoveTxns,
    Buf2 = filter_txn_buffer(Buf1, Chain),
    log_and_reset_validation_metrics(),
    {reply, Buf2, State};
handle_call({prefilter_round, _Buf, _RemoveTxns}, _From, #state{chain = undefined} = State) ->
    {reply, [], State};
handle_call({prefilter_round, Buf, PendingTxns}, _From, #state{chain = Chain} = State) ->
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:reset_context(Ledger),
    %% pre-seed the ledger with the pending txns from the next block
    try
        [ ok = blockchain_txn:absorb(P, Chain) || P <- PendingTxns ]
    catch _:_ ->
              %% if this doesn't work, it means the ledger advanced out from under us
              %% so just reset the ledger and continue
              blockchain_ledger_v1:reset_context(Ledger)
    end,
    %% filter the buffer in light of the pending next block
    Buf2 = filter_txn_buffer(Buf, Chain),
    {reply, Buf2, State};

handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({Ref, {Res, Height}}, #state{validations = Validations, chain = Chain, group = Group} = State)
  when is_reference(Ref) ->
    case maps:get(Ref, Validations, undefined) of
        undefined ->
            case Res of
                {error, validation_deadline} ->
                    %% these are expected from the validation timer below
                    ok = update_validation_metric(?TIMEDOUT_TXNS, unknown_type),
                    ok;
                _ ->
                    lager:warning("response for unknown ref [~p]: ~p", [Ref, Res])
            end,
            {noreply, State};
        #validation{from = From, pid = Pid, txn = Txn, monitor = MRef} ->
            Type = blockchain_txn:type(Txn),
                case Res of
                    ok ->
                        ok = update_validation_metric(?VALID_TXNS, Type),
                        case blockchain_txn:absorb(Txn, Chain) of
                            ok ->
                                %% avoid deadlock by not waiting for this.
                                spawn(fun() ->
                                            {ok, PosInQueue, QueueLen} = libp2p_group_relcast:handle_command(Group, {txn, Txn}),
                                            gen_server:reply(From, {ok, PosInQueue, QueueLen, Height})
                                      end),
                                ok;
                            Error ->
                                lager:warning("speculative absorb failed for ~s, error: ~p", [blockchain_txn:print(Txn), Error]),
                                Error
                        end;
                    {error, validation_deadline}=Error ->
                        erlang:exit(Pid, kill),
                        write_txn("timed out", Height, Txn),
                        ok = update_validation_metric(?TIMEDOUT_TXNS, Type),
                        lager:warning("validation timed out for ~s", [blockchain_txn:print(Txn)]),
                        gen_server:reply(From, {Error, Height}),
                        ok;
                    {error, Error} ->
                        write_txn("failed", Height, Txn),
                        ok = update_validation_metric(?INVALID_TXNS, Type),
                        lager:warning("is_valid failed for ~s, error: ~p", [blockchain_txn:print(Txn), Error]),
                        gen_server:reply(From, {Error, Height}),
                        ok
                end,
            erlang:demonitor(MRef, [flush]),
            Validations1 = maps:remove(Ref, Validations),
            {noreply, maybe_start_validation(State#state{validations = Validations1})}
    end;
handle_info(
    {'DOWN', Ref, process, _Pid, Reason},
    #state{validations = Validations, chain = Chain} = State
) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
    case maps:to_list(maps:filter(
                        fun(_K, #validation{monitor = MRef}) when Ref == MRef -> true;
                           (_, _) -> false end,
                        Validations)) of
        [{Attempt, #validation{from = From, txn = Txn}}] ->
            Result = {error, validation_crashed},
            gen_server:reply(From, {Result, Height}),
            Validations1 = maps:remove(Attempt, Validations),
            ok = update_validation_metric(?INVALID_TXNS, blockchain_txn:type(Txn)),
            {noreply, maybe_start_validation(State#state{validations = Validations1})};
        _ ->
            lager:warning("DOWN msg for unknown ref. pid = ~p reason = ", [_Pid, Reason]),
            {noreply, State}
   end;
handle_info(chain_check, State) ->
    {ok, State1} = init(State),
    {noreply, State1};
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, #state{validations = Validations, chain = Chain}) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
    Result = {error, exiting},
    maps:map(
      fun(_K, #validation{from = From, pid = Pid}) ->
              gen_server:reply(From, {Result, Height}),
              erlang:exit(Pid, kill)
      end, Validations),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

filter_txn_buffer(Buf, Chain) ->
    lists:filter(fun(BinTxn) ->
                         Txn = blockchain_txn:deserialize(BinTxn),
                         IsSlow = maps:is_key(blockchain_txn:type(Txn), ?SlowTxns),
                         case IsSlow orelse blockchain_txn:is_valid(Txn, Chain) == ok of
                             true ->
                                 case blockchain_txn:absorb(Txn, Chain) of
                                     ok ->
                                         true;
                                     Other ->
                                         lager:info("Transaction ~s could not be re-absorbed ~p",
                                                    [blockchain_txn:print(Txn), Other]),
                                         false
                                 end;
                             Other ->
                                 lager:info("Transaction ~s became invalid ~p", [blockchain_txn:print(Txn), Other]),
                                 false
                         end
                 end, Buf).

write_txn(Reason, Height, Txn) ->
    case application:get_env(miner, write_failed_txns, false) of
        true ->
            Name = ["/tmp/", io_lib:format("height-~b-hash-~b",
                                           [Height, erlang:phash2(Txn)]), ".txn"],
            ok = file:write_file(Name, blockchain_txn:serialize(Txn)),
            lager:info("~s txn written to disk as ~s", [Reason, Name]),
            ok;
        _ ->
            ok
    end.

maybe_start_validation(#state{queue = Queue, chain = Chain,
                              validations = Validations} = State) ->
    case Queue of
        [] ->
            State;
        [{From, Txn, Height} | Queue1] ->
            Type = blockchain_txn:type(Txn),
            Timeout = maps:get(Type, ?SlowTxns, application:get_env(miner, txn_validation_budget_ms, 10000)),
            {Attempt, V} = start_validation(Txn, Height, From, Timeout, Chain),
            Validations1 = Validations#{Attempt => V},
            State#state{validations = Validations1, queue = Queue1}
    end.

start_validation(Txn, Height, From, Timeout, Chain) ->
    Owner = self(),
    Attempt = make_ref(),
    {Pid, Ref} =
        spawn_monitor(
          fun() ->
                  Result =
                      case blockchain_txn:is_valid(Txn, Chain) of
                          ok ->
                              ok;
                          Error ->
                              lager:debug("hbbft_handler is_valid failed for ~s, error: ~p", [blockchain_txn:print(Txn), Error]),
                              {error, Error}
                      end,
                    Owner ! {Attempt, {Result, Height}}
          end),
    TRef = erlang:send_after(Timeout, self(), {Attempt, {{error, validation_deadline}, Height}}),
    {Attempt,
     #validation{timer = TRef, monitor = Ref, txn = Txn, pid = Pid, from = From, height=Height}}.

oversized_txn(Txn, Ledger) ->
    BlockSizeLimit =
        case blockchain:config(?block_size_limit, Ledger) of
            {ok, SizeLimit} when is_integer(SizeLimit) -> SizeLimit;
            _ -> 50*1024*1024
        end,
    byte_size(blockchain_txn:serialize(Txn)) > BlockSizeLimit.

get_config(Var, Default, Ledger) ->
    case blockchain:config(Var, Ledger) of
        {ok, V} -> V;
        _ -> Default
    end.

update_validation_metric(ResultType, TxnType) ->
    case get(ResultType) of
        undefined ->
            put(ResultType, #{TxnType => 1});
        TxnMap when is_map(TxnMap) ->
            put(ResultType, maps:update_with(TxnType, fun(Count) -> Count + 1 end, 1, TxnMap))
    end,
    ok.

log_and_reset_validation_metrics() ->
    [
      begin
          TypeTxnsMap = erase(Type),
          lager:info("~p txns for the current round: ~p", [Type, TypeTxnsMap])
      end || Type <- ?VALIDATION_METRICS
    ],
    ok.
