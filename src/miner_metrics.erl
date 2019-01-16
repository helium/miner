-module(miner_metrics).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    poc_req_rate/1,
    record_queues/0,
    record_vm_stats/0
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-define(Q_LENGTH(Name), [erlang, vm, offenders, message_queue_len, Name]).
-define(POC_REQ_RATE, [miner, poc, req, rate]).

-define(STATIC_METRICS, [
    {?POC_REQ_RATE, meter}
]).


-define(REPORTER, exometer_report_graphite).
-define(DEFAULT_GRAPHITE, [
    {prefix, "miner"},
    {host, "127.0.0.1"},
    {port, 2003},
    {api_key, ""}
]).

-record(state, {
    interval,
    reporter
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec poc_req_rate(integer()) -> 'ok'.
poc_req_rate(Int) ->
    gen_server:cast(?SERVER, {'update', ?POC_REQ_RATE, Int}).

%%--------------------------------------------------------------------
%% @doc
%% Record processes with highest message queue length
%% @end
%%--------------------------------------------------------------------
-spec record_queues() -> ok.
record_queues() ->
    Offenders = recon:proc_count(message_queue_len, 2),
    lists:foreach(
        fun({_Pid, Length, _Extra}) when Length < 1000 ->
            ok;
        ({Pid, Length, _Extra}) ->
            case erlang:is_process_alive(Pid)  of
                false -> ok;
                true ->
                    Name = get_pid_name(Pid),
                    gen_server:cast(?SERVER, {update_create, ?Q_LENGTH(Name), Length, histogram})
            end
        end
        ,Offenders
    ),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Record VM stats (memory and cpu)
%% @end
%%--------------------------------------------------------------------
-spec record_vm_stats() -> list().
record_vm_stats() ->
    [{Mem, CPU}] = recon:node_stats_list(1, 1),
    SchedulerUsage = lists:map(
        fun({Num, Usage}) ->
            Str = string:join(["cpu", integer_to_list(Num)], "_"),
            {[cpu, list_to_atom(Str)], Usage, gauge}
        end
        ,proplists:get_value(scheduler_usage, CPU, [])
    ),
    Stats = [
        {[memory, memory_total], proplists:get_value(memory_total, Mem, 0), gauge},
        {[memory, memory_procs], proplists:get_value(memory_procs, Mem, 0), gauge},
        {[memory, memory_atoms], proplists:get_value(memory_atoms, Mem, 0), gauge},
        {[memory, memory_bin], proplists:get_value(memory_bin, Mem, 0), gauge},
        {[memory, memory_ets], proplists:get_value(memory_ets, Mem, 0), gauge},
        {[others, process_count], proplists:get_value(process_count, Mem, 0), gauge}
    ] ++ SchedulerUsage,

    lists:foreach(
        fun({Name, Data, Type}) ->
            gen_server:cast(?SERVER, {update_create, [erlang, vm] ++ Name, Data, Type})
        end
        ,Stats
    ),
    Stats.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    Interval = proplists:get_value(interval, Args, 5000),
    Reporter = proplists:get_value(graphite, Args, ?DEFAULT_GRAPHITE),

    ok = exometer_report:add_reporter(?REPORTER, Reporter),

    lists:foreach(
        fun({Metric, Type}) ->
            ok = exometer:re_register(Metric, Type, []),
            exometer_report:subscribe(?REPORTER, Metric, datapoints(Type), Interval)
        end,
        ?STATIC_METRICS
    ),

    lists:foreach(
        fun({Metric, _Data, Type}) ->
            exometer_report:subscribe(?REPORTER, [erlang, vm] ++ Metric, datapoints(Type), Interval, [], true)
        end,
        record_vm_stats()
    ),

    exometer_report:subscribe(
        ?REPORTER,
        {select, [{{[erlang, vm, offenders, '_', '_'], '_', '_'}, [], ['$_']}]},
        datapoints('histogram'),
        Interval
    ),

    lager:info("init ~p", [Args]),
    self() ! record_queues,
    self() ! record_vm_stats,

    {ok, #state{interval=Interval, reporter=Reporter}}.

handle_call(_Msg, _From, State) ->
    lager:debug("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast({update, Metric, Value}, State) ->
    _ = exometer:update(Metric, Value),
    {noreply, State};
handle_cast({update_create, Metric, Value, Type}, State) ->
    _ = exometer:update_or_create(Metric, Value, Type, []),
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(record_queues, #state{interval=Interval}=State) ->
    erlang:spawn(?MODULE, record_queues, []),
    erlang:send_after(Interval, self(), record_queues),
    {noreply, State};
handle_info(record_vm_stats, #state{interval=Interval}=State) ->
    erlang:spawn(?MODULE, record_vm_stats, []),
    erlang:send_after(Interval, self(), record_vm_stats),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:notice("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    lager:error("~p terminated: ~p", [?MODULE, _Reason]),
    exometer_report:remove_reporter(?REPORTER),
    {ok, Metrics} = exometer_report:list_metrics(),
    lists:foreach(
        fun({Name, _, _, _}) ->
            exometer:delete(Name)
        end
        ,Metrics
    ),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_pid_name(pid()) -> atom().
get_pid_name(Pid) ->
    case recon:info(Pid, registered_name) of
        [] -> format_pid(Pid);
        {registered_name, Name} -> Name;
        _Else -> format_pid(Pid)
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec format_pid(pid()) -> atom().
format_pid(Pid) ->
    Bin = list_to_binary(pid_to_list(Pid)),
    Bin1 = binary:replace(Bin, <<".">>, <<"-">>, [global]),
    list_to_atom(binary_to_list(Bin1)).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec datapoints(atom()) -> list().
datapoints(counter) -> [value];
datapoints(gauge) -> [value];
datapoints(histogram) -> [mean, min, max, 50, 95, 99, 999];
datapoints(meter) -> [count, one, five, fifteen, day, mean].
