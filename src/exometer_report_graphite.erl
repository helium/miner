-module(exometer_report_graphite).
-behaviour(exometer_report).

%% gen_server callbacks
-export([
    exometer_init/1,
    exometer_info/2,
    exometer_cast/2,
    exometer_call/3,
    exometer_report/5,
    exometer_subscribe/5,
    exometer_unsubscribe/4,
    exometer_newentry/2,
    exometer_setopts/4,
    exometer_terminate/2
]).

-include_lib("exometer_core/include/exometer.hrl").

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 2003).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

-record(state, {
    state = 'undefined',
    host = ?DEFAULT_HOST,
    port = ?DEFAULT_PORT,
    timeout = ?DEFAULT_CONNECT_TIMEOUT,
    name,
    namespace = [],
    prefix = [],
    api_key = "",
    socket = 'undefined'
}).

%% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(UNIX_EPOCH, 62167219200).

%% Probe callbacks
exometer_init(Opts) ->
    lager:info("init with: ~p", [Opts]),
    APIKey = proplists:get_value('api_key', Opts, ""),
    Prefix = proplists:get_value('prefix', Opts, ""),
    Host = proplists:get_value('host', Opts, ?DEFAULT_HOST),
    Port = proplists:get_value('port', Opts, ?DEFAULT_PORT),
    Timeout = proplists:get_value('timeout', Opts, ?DEFAULT_CONNECT_TIMEOUT),

    self() ! 'connect',

    {'ok', #state{
        state='connecting',
        prefix=Prefix,
        api_key=APIKey,
        host=Host,
        port=Port,
        timeout=Timeout
    }}.

exometer_report(_Probe, _DataPoint, _Extra, _Value, #state{socket='undefined', state='connecting'}=State) ->
    {'ok', State};
exometer_report(_Probe, _DataPoint, _Extra, _Value, #state{socket='undefined'}=State) ->
    lager:warning("error sending data to graphite: no socket found"),
    self() ! 'connect',
    {'ok', State#state{state='connecting'}};
exometer_report(Probe, DataPoint, _Extra, Value, #state{socket=Sock,
                                                        api_key=APIKey,
                                                        prefix=Prefix}=State) ->
    Line = [key(APIKey, Prefix, Probe, DataPoint), " ",
            value(Value), " ", timestamp(), $\n],
    case gen_tcp:send(Sock, Line) of
        'ok' ->
            {'ok', State};
        Error ->
            lager:warning("error sending data to graphite: ~p", [Error]),
            _ = gen_tcp:close(Sock),
            self() ! 'connect',
            {'ok', State#state{socket='undefined', state='connecting'}}
    end.

exometer_subscribe(_Metric, _DataPoint, _Extra, _Interval, State) ->
    {'ok', State}.

exometer_unsubscribe(_Metric, _DataPoint, _Extra, State) ->
    {'ok', State}.

exometer_call(Unknown, From, State) ->
    lager:debug("unknown call ~p from ~p", [Unknown, From]),
    {'ok', State}.

exometer_cast(Unknown, State) ->
    lager:debug("unknown cast: ~p", [Unknown]),
    {'ok', State}.

exometer_info('connect', #state{host=Host, port=Port}=State) ->
    lager:info("connecting to graphite with ~p:~p", [Host, Port]),
    case gen_tcp:connect(Host, Port, [{'mode', 'list'}], State#state.timeout) of
        {'ok', Sock} ->
            lager:info("connected to graphite"),
            {'ok', State#state{socket=Sock, state='connected'}};
        {'error', _}=Error ->
            lager:warning("error connecting to graphite: ~p", [Error]),
            timer:sleep(State#state.timeout),
            self() ! 'connect',
            {'ok', State#state{socket='undefined', state='connecting'}}
    end;
exometer_info(Unknown, State) ->
    lager:debug("unknown info: ~p", [Unknown]),
    {'ok', State}.

exometer_newentry(_Entry, State) ->
    {'ok', State}.

exometer_setopts(_Metric, _Options, _Status, State) ->
    {'ok', State}.

exometer_terminate(_, _) ->
    'ignore'.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% Format a graphite key from API key, prefix, prob and datapoint
%% @end
%%--------------------------------------------------------------------
key([], [], Prob, DataPoint) ->
    name(Prob, DataPoint);
key([], Prefix, Prob, DataPoint) ->
    [Prefix, $., name(Prob, DataPoint)];
key(APIKey, [], Prob, DataPoint) ->
    [APIKey, $., name(Prob, DataPoint)];
key(APIKey, Prefix, Prob, DataPoint) ->
    [APIKey, $., Prefix, $., name(Prob, DataPoint)].


%%--------------------------------------------------------------------
%% @doc
%% Add probe and datapoint within probe
%% @end
%%--------------------------------------------------------------------
name(Probe, DataPoint) ->
    [[[metric_elem_to_list(I), $.] || I <- Probe], datapoint(DataPoint)].

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
metric_elem_to_list(V) when is_atom(V) -> atom_to_list(V);
metric_elem_to_list(V) when is_binary(V) -> binary_to_list(V);
metric_elem_to_list(V) when is_integer(V) -> integer_to_list(V);
metric_elem_to_list(V) when is_list(V) -> V.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
datapoint(V) when is_integer(V) -> integer_to_list(V);
datapoint(V) when is_atom(V) -> atom_to_list(V).

%%--------------------------------------------------------------------
%% @doc
%% Add value, int or float, converted to list
%% @end
%%--------------------------------------------------------------------
value(V) when is_integer(V) -> integer_to_list(V);
value(V) when is_float(V)   -> float_to_list(V);
value(_) -> 0.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
timestamp() ->
    integer_to_list(unix_time()).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
unix_time() ->
    datetime_to_unix_time(erlang:universaltime()).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
datetime_to_unix_time({{_, _, _}, {_, _, _}} = DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) - ?UNIX_EPOCH.
