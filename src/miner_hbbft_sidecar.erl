-module(miner_hbbft_sidecar).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain.hrl").

% API
-export([
         start_link/0,
         submit/1,
         set_group/1,
         new_round/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(SlowTxns, [blockchain_txn_poc_receipts_v1,
                   blockchain_txn_consensus_group_v1]).

-record(validation,
        {
         timer :: reference(),
         monitor :: reference(),
         pid :: pid(),
         txn :: blockchain_txn:txn(),
         from :: {pid(), term()} % gen server doesn't export this?!?!
        }).

-record(state,
        {
         chain :: undefined | blockchain:blockchain(),
         group :: undefined | pid(),
         queue = [] :: [blockchain_txn:txn()],
         validations = #{} :: #{reference() => #validation{}}
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

submit(Txn) ->
    lager:debug("submitting txn"),
    gen_server:call(?SERVER, {submit, Txn}, infinity).

set_group(Group) ->
    lager:debug("setting group to ~p", [Group]),
    gen_server:call(?SERVER, {set_group, Group}, infinity).

new_round(Buf, Txns) ->
    gen_server:call(?SERVER, {new_round, Buf, Txns}, infinity).

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
            Ledger = blockchain_ledger_v1:new_context(blockchain:ledger(Chain)),
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
            ok = libp2p_swarm:add_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL,
                                                 {libp2p_framed_stream, server,
                                                  [blockchain_txn_handler, self(),
                                                   fun(T) -> miner_hbbft_sidecar:submit(T) end]});
        {P, undefined} when is_pid(P) ->
            libp2p_swarm:remove_stream_handler(blockchain_swarm:swarm(), ?TX_PROTOCOL)
    end,
    {reply, ok, State#state{group = Group}};
handle_call({submit, _}, _From, #state{group = undefined} = State) ->
    lager:debug("submission with no group set"),
    {reply, {error, no_group}, State};
handle_call({submit, Txn}, From,
            #state{chain = Chain,
                   group = Group,
                   queue = Queue,
                   validations = Validations} = State) ->
    Type = blockchain_txn:type(Txn),
    lager:debug("got submission of txn: ~s", [blockchain_txn:print(Txn)]),
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
    case lists:member(Type, ?SlowTxns) of
        true ->
            Limit = application:get_env(miner, sidecar_parallelism_limit, 3),
            case maps:size(Validations) of
                N when N >= Limit ->
                    Queue1 = Queue ++ [{From, Txn}],
                    {noreply, State#state{queue = Queue1}};
                _ ->
                    {Attempt, V} = start_validation(Txn, From, Chain),
                    {noreply, State#state{validations = Validations#{Attempt => V}}}
            end;
        false ->
            case blockchain_txn:is_valid(Txn, Chain) of
                ok ->
                    case blockchain_txn:absorb(Txn, Chain) of
                        ok ->
                            catch libp2p_group_relcast:handle_command(Group, Txn),
                            {reply, ok, State};
                        Error ->
                            lager:warning("speculative absorb failed for ~p, error: ~p", [Txn, Error]),
                            {reply, Error, State}
                    end;
                Error ->
                    write_txn("failed", Height, Txn),
                    lager:debug("is_valid failed for ~p, error: ~p", [Txn, Error]),
                    {reply, Error, State}
            end
    end;
handle_call({new_round, _Buf, _RemoveTxns}, _From, #state{chain = undefined} = State) ->
    {reply, [], State};
handle_call({new_round, Buf, RemoveTxns}, _From, #state{chain = Chain} = State) ->
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:reset_context(Ledger),
    Buf1 = Buf -- RemoveTxns,
    Buf2 = filter_txn_buffer(Buf1, Chain),
    {reply, Buf2, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({Ref, Res}, #state{validations = Validations, chain = Chain, group = Group} = State)
  when is_reference(Ref) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
    case maps:get(Ref, Validations, undefined) of
        undefined ->
            lager:warning("response for unknown ref"),
            {noreply, State};
        #validation{from = From, pid = Pid, txn = Txn, monitor = MRef} ->
            Reply =
                case Res of
                    ok ->
                        case blockchain_txn:absorb(Txn, Chain) of
                            ok ->
                                %% avoid deadlock by not waiting for this.
                                spawn(fun() ->
                                              catch libp2p_group_relcast:handle_command(Group, Txn)
                                      end),
                                ok;
                            Error ->
                                lager:warning("speculative absorb failed for ~p, error: ~p", [Txn, Error]),
                                Error
                        end;
                    deadline ->
                        erlang:exit(Pid, kill),
                        write_txn("timed out", Height, Txn),
                        {error, validation_deadline};
                    {error, Error} ->
                        write_txn("failed", Height, Txn),
                        lager:warning("is_valid failed for ~p, error: ~p", [Txn, Error]),
                        Error
                end,
            erlang:demonitor(MRef, [flush]),
            gen_server:reply(From, Reply),
            Validations1 = maps:remove(Ref, Validations),
            {noreply, maybe_start_validation(State#state{validations = Validations1})}
    end;
handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{validations = Validations} = State) ->
    case maps:to_list(maps:filter(
                        fun(_K, #validation{monitor = MRef}) when Ref == MRef -> true;
                           (_, _) -> false end,
                        Validations)) of
        [{Attempt, #validation{from = From}}] ->
            gen_server:reply(From, {error, validation_crashed}),
            Validations1 = maps:remove(Attempt, Validations),
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

terminate(_Reason, #state{validations = Validations}) ->
    maps:map(
      fun(_K, #validation{from = From, pid = Pid}) ->
              gen_server:reply(From, {error, exiting}),
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
                         IsSlow = lists:member(blockchain_txn:type(Txn), ?SlowTxns),
                         case IsSlow orelse blockchain_txn:is_valid(Txn, Chain) == ok of
                             true ->
                                 case blockchain_txn:absorb(Txn, Chain) of
                                     ok ->
                                         true;
                                     Other ->
                                         lager:info("Transaction ~p could not be re-absorbed ~p",
                                                    [Txn, Other]),
                                         false
                                 end;
                             Other ->
                                 lager:info("Transaction ~p became invalid ~p", [Txn, Other]),
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
        [{From, Txn} | Queue1] ->
            {Attempt, V} = start_validation(Txn, From, Chain),
            Validations1 = Validations#{Attempt => V},
            State#state{validations = Validations1, queue = Queue1}
    end.

start_validation(Txn, From, Chain) ->
    Owner = self(),
    Attempt = make_ref(),
    Timeout = application:get_env(miner, txn_validation_budget_ms, 10000),
    {Pid, Ref} =
        spawn_monitor(
          fun() ->
                  case blockchain_txn:is_valid(Txn, Chain) of
                      ok ->
                          Owner ! {Attempt, ok};
                      Error ->
                          lager:debug("hbbft_handler is_valid failed for ~p, error: ~p", [Txn, Error]),
                          Owner ! {Attempt, {error, Error}}
                  end
          end),
    TRef = erlang:send_after(Timeout, self(), {Attempt, deadline}),
    {Attempt,
     #validation{timer = TRef, monitor = Ref, txn = Txn, pid = Pid, from = From}}.
