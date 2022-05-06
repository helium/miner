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
        [] -> ignore;
        Metrics ->
            erlang:process_flag(trap_exit, true),

            ok = setup_metrics(Metrics),

            ElliOpts = [
                {callback, miner_metrics_reporter},
                {callback_args, #{}},
                {port, proplists:get_value(port, [], 9090)}
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

setup_metrics(Metrics) ->
    lager:warning("METRICS ~p", [Metrics]),
    lists:foreach(
        fun({Metric, Event, Module, Meta, Description}) ->
            lager:info("Declaring metric ~p as ~p meta=~p", [Metric, Module, Meta]),
            case Module of
                prometheus_histogram ->
                    Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta},
                        {buckets, ?METRICS_HISTOGRAM_BUCKETS}
                    ]);
                _ ->
                    Module:declare([
                        {name, Metric},
                        {help, Description},
                        {labels, Meta}
                    ])
            end,

            ok = telemetry:attach(list_to_binary(Metric), Event, fun miner_metrics_server:handle_metric/4, [])
        end,
        Metrics
    ).

get_configs() ->
    lists:foldl(
        fun(Metric, Acc) ->
            case maps:get(Metric, ?METRICS, undefined) of
                undefined -> Acc;
                Result -> Acc ++ Result
            end
        end,
        [],
        application:get_env(miner, metrics, [])
    ).

handle_metric_event([blockchain, block, absorb], #{duration := Duration}, #{stage := Stage}) ->
    prometheus_histogram:observe(?METRICS_BLOCK_ABSORB, [Stage], Duration),
    ok;
handle_metric_event([blockchain, block, height], #{height := Height}, #{time := Time}) ->
    prometheus_gauge:set(?METRICS_BLOCK_HEIGHT, [Time], Height),
    ok.
