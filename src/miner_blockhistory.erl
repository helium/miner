-module(miner_blockhistory).

-behavior(gen_server).

-record(state, {
    url,
    historical_block=0,
    historical_time=0,
    last_retrieved_time=0
}).

-define(HISTORICAL_TIME_FETCH_INTERVAL, 3600).

-export([init/1, handle_info/2, handle_cast/2, handle_call/3]).

-export([start_link/0, get_history/0]).

start_link() ->
    BaseURL = application:get_env(miner, api_base_url, "https://api.helium.io/v1"),
    URL = string:concat(BaseURL, "/blocks/"),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [URL], []).

-spec get_history() -> {ok, {non_neg_integer(), non_neg_integer()}} | undefined.
get_history() ->
    gen_server:call(?MODULE, get_history).

%% gen_server callbacks

init([URL]) ->
    {ok, schedule_check(#state{url=URL}, 15)}.

handle_info(check, #state{url=URL}=State) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:info("No chain, retry soon"),
            {ok, schedule_check(State, timer:seconds(15))};
        Chain ->
            Ledger = blockchain:ledger(Chain),
            case blockchain_ledger_v1:current_height(Ledger) of
                {ok, CurrentHeight} ->
                    StabilizationPeriod = application:get_env(miner, stabilization_period, 0),
                    HistoryHeight = max(1, CurrentHeight - StabilizationPeriod),
                    HeightURL = string:concat(URL, integer_to_list(HistoryHeight)),
                    case httpc:request(get, {HeightURL, [{"user-agent", "ValidatorHistoricalHeight/0.0.1"}] }, [], [{body_format, binary}]) of
                        {ok, {{_HttpVersion, 200, "OK"}, _Headers, Body}} ->
                            try jsx:decode(Body, [{return_maps, true}]) of
                                Json ->
                                    case maps:get(<<"data">>, Json, undefined) of
                                        undefined ->
                                            lager:debug("api response didn't contain data"),
                                            {noreply, schedule_check(State)};
                                        Data ->
                                            case maps:get(<<"time">>, Data, undefined) of
                                                undefined ->
                                                    lager:debug("api response didn't contain time"),
                                                    {noreply, schedule_check(State)};
                                                HistoricalTime ->
                                                    {noreply, schedule_check(State#state{historical_block=HistoryHeight, historical_time=HistoricalTime, last_retrieved_time=erlang:monotonic_time(second)})}
                                            end
                                    end
                            catch _:_ ->
                                lager:notice("failed to get historic block time: ~p", [Body]),
                                {noreply, schedule_check(State)}
                            end;
                        OtherHttpResult ->
                            lager:notice("failed to get historic block time: ~p", [OtherHttpResult]),
                            {noreply, schedule_check(State)}
                    end
            end
    end;
handle_info(Msg, State) ->
    lager:info("unhandled info msg ~p", [Msg]),
    {noreply, State}.

handle_cast(Msg, State) ->
    lager:info("unhandled cast msg ~p", [Msg]),
    {noreply, State}.

handle_call(get_history, _From, #state{historical_block=HistoricalBlock, historical_time=HistoricalTime}=State) ->
    case HistoricalBlock > 0 andalso HistoricalTime > 0 of
        true ->
            {reply, {ok, {HistoricalBlock, HistoricalTime}}, State};
        false ->
            {reply, undefined, State}
    end;
handle_call(Msg, _From, State) ->
    lager:info("unhandled call msg ~p", [Msg]),
    {reply, ok, State}.

schedule_check(State) ->
    FetchInterval = application:get_env(miner, historical_time_fetch_interval, ?HISTORICAL_TIME_FETCH_INTERVAL),
    schedule_check(State, timer:seconds(FetchInterval)).

schedule_check(State, Time) ->
    erlang:send_after(Time, self(), check),
    State.

