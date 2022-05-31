-module(miner_metrics_server).

-behaviour(gen_server).

-include("metrics.hrl").

-export([
    handle_metric/4,
    start_link/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-type metric() :: {
    Metric :: string(),
    Event :: [atom()],
    PrometheusHandler :: module(),
    Labels :: [atom()],
    Description :: string()
}.
-type metrics() :: [metric()].

-type reporter_opts() :: [
    {callback, module()} |
    {callback_args, map()} |
    {port, integer()}
].

-record(state, {
    metrics :: metrics(),
    reporter_opts :: reporter_opts(),
    reporter_pid :: pid() | undefined
}).

handle_metric(Event, Measurements, Metadata, _Config) ->
    handle_metric_event(Event, Measurements, Metadata).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, [], []).

init(_Args) ->
    case get_configs() of
        {[], []} -> ignore;
        {[_ | _], [_ | _]} = Metrics ->
            erlang:process_flag(trap_exit, true),

            ok = setup_metrics(Metrics),

            ElliOpts = [
                {callback, miner_metrics_reporter},
                {callback_args, #{}},
                {port, application:get_env(miner, metrics_port, 9090)}
            ],
            {ok, ReporterPid} = elli:start_link(ElliOpts),
            {ok, #state{
                        metrics = Metrics,
                        reporter_opts = ElliOpts,
                        reporter_pid = ReporterPid}}
    end.

handle_call(_Msg, _From, State) ->
    lager:debug("Received unknown call msg: ~p from ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', ReporterPid, Reason}, #state{reporter_pid=ReporterPid} = State) ->
    lager:warning("Metrics reporter exited with reason ~p, restarting", [Reason]),
    {ok, NewReporter} = elli:start_link(State#state.reporter_opts),
    {noreply, State#state{reporter_pid = NewReporter}};
handle_info(_Msg, State) ->
    lager:debug("Received unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #state{metrics = Metrics, reporter_pid = Reporter}) ->
    true = erlang:exit(Reporter, Reason),
    lists:foreach(
        fun({Metric, _, Module, _, _}) ->
            lager:info("De-registering metric ~p as ~p", [Metric, Module]),
            Module:deregister(Metric)
        end,
        Metrics
    ).

setup_metrics({EventNames, EventSpecs}) ->
    lager:warning("METRICS ~p", [EventSpecs]),
    lists:foreach(
        fun({Metric, Module, Meta, Description}) ->
            lager:info("Declaring metric ~p as ~p meta=~p", [Metric, Module, Meta]),
            MetricOpts = [{name, Metric}, {help, Description}, {labels, Meta}],
            case Module of
                prometheus_histogram ->
                    Module:declare(MetricOpts ++ [{buckets, ?METRICS_HISTOGRAM_BUCKETS}]);
                _ ->
                    Module:declare(MetricOpts)
            end
        end,
        EventSpecs
    ),

    ok = telemetry:attach_many(<<"miner-metrics-handler">>, EventNames, fun miner_metrics_server:handle_metric/4, []).

get_configs() ->
    lists:foldl(
        fun(Metric, {Names, Specs} = Acc) ->
            case maps:get(Metric, ?METRICS, undefined) of
                undefined -> Acc;
                {N, S} -> {Names ++ N, Specs ++ S}
            end
        end,
        {[], []},
        application:get_env(miner, metrics, [])
    ).

handle_metric_event([blockchain, block, absorb], #{duration := Duration}, #{stage := Stage}) ->
    prometheus_histogram:observe(?METRICS_BLOCK_ABSORB, [Stage], Duration),
    ok;
handle_metric_event([blockchain, block, height], #{height := Height}, #{time := Time}) ->
    prometheus_gauge:set(?METRICS_BLOCK_HEIGHT, [Time], Height),
    ok;
handle_metric_event([blockchain, block, unvalidated_absorb], #{duration := Duration}, #{stage := Stage}) ->
    prometheus_histogram:observe(?METRICS_BLOCK_UNVAL_ABSORB, [Stage], Duration),
    ok;
handle_metric_event([blockchain, block, unvalidated_height], #{height := Height}, #{time := Time}) ->
    prometheus_gauge:set(?METRICS_BLOCK_UNVAL_HEIGHT, [Time], Height),
    ok;
handle_metric_event([blockchain, txn, absorb], #{duration := Duration}, #{type := Type}) ->
    prometheus_histogram:observe(?METRICS_TXN_ABSORB_DURATION, [Type], Duration),
    ok;
handle_metric_event([blockchain, txn_mgr, submit], _Measurements, #{type := Type}) ->
    prometheus_counter:inc(?METRICS_TXN_SUBMIT_COUNT, [Type]),
    ok;
handle_metric_event([blockchain, txn_mgr, reject], #{block_span := Span}, #{type := Type}) ->
    prometheus_counter:inc(?METRICS_TXN_REJECT_COUNT, [Type]),
    prometheus_gauge:set(?METRICS_TXN_REJECT_SPAN, [Type], Span),
    ok;
handle_metric_event([blockchain, txn_mgr, accept], #{block_span := Span}, #{type := Type}) ->
    prometheus_counter:inc(?METRICS_TXN_ACCEPT_COUNT, [Type]),
    prometheus_gauge:set(?METRICS_TXN_ACCEPT_SPAN, [Type], Span),
    ok;
handle_metric_event([blockchain, txn_mgr, process], #{duration := Duration}, #{stage := Stage}) ->
    prometheus_histogram:observe(?METRICS_TXN_PROCESS_DURATION, [Stage], Duration),
    ok;
handle_metric_event([blockchain, txn_mgr, add_block], #{cache := Cache, block_time := BlockTime, block_age := BlockAge},
                                                      #{height := Height}) ->
    prometheus_gauge:set(?METRICS_TXN_CACHE_SIZE, [Height], Cache),
    prometheus_gauge:set(?METRICS_TXN_BLOCK_TIME, [Height], BlockTime),
    prometheus_gauge:set(?METRICS_TXN_BLOCK_AGE, [Height], BlockAge),
    ok;
handle_metric_event([blockchain, state_channel, open], _Measurements, #{version := Vzn, id := Id}) ->
    prometheus_gauge:inc(?METRICS_SC_COUNT, [Vzn, Id]),
    ok;
handle_metric_event([blockchain, state_channel, close], _Measurements, #{version := Vzn, id := Id}) ->
    prometheus_gauge:dec(?METRICS_SC_COUNT, [Vzn, Id]),
    ok;
handle_metric_event([grpcbox, server, rpc_end], #{server_latency := Latency},
                                                #{grpc_server_method := Method, grpc_server_status := Status}) ->
    prometheus_gauge:dec(?METRICS_GRPC_SESSIONS, [Method]),
    prometheus_histogram:observe(?METRICS_GRPC_LATENCY, [Method, Status], Latency),
    ok;
handle_metric_event([grpcbox, server, rpc_begin], _Measurements, #{grpc_server_method := Method}) ->
    prometheus_gauge:inc(?METRICS_GRPC_SESSIONS, [Method]),
    ok;
handle_metric_event([blockchain, snapshot, generate], #{duration := Duration, size := Size},
                                                      #{blocks := Blocks, version := Vzn}) ->
    prometheus_gauge:set(?METRICS_SNAP_GEN_SIZE, [Blocks, Vzn], Size),
    prometheus_gauge:set(?METRICS_SNAP_GEN_DURATION, [Blocks, Vzn], Duration),
    ok;
handle_metric_event([blockchain, snapshot, load], #{duration := Duration, size := Size},
                                                  #{height := Height, hash := Hash, version := Vzn, source := Source}) ->
    prometheus_gauge:set(?METRICS_SNAP_LOAD_SIZE, [Height, Hash, Vzn, Source], Size),
    prometheus_gauge:set(?METRICS_SNAP_LOAD_DURATION, [Height, Hash, Vzn, Source], Duration),
    ok.
