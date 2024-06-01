-module(miner_telemetry).
-behaviour(gen_server).
-include("miner_jsonrpc.hrl").

-export([start_link/0, log/2, toggle_always_send/0]).

-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

%% defines how frequently we send telemetry when a node is in consensus (seconds)
-define(CONSENSUS_TELEMETRY_INTERVAL, 30 * 1000).
-define(TELEMETRY_SEND_INTERVAL, 100). %% blocks

-record(state, {
    logs = [] :: [ binary() ],
    traces = [] :: [ atom() ],
    counts = #{} :: map(),
    timer = make_ref() :: reference(),
    last_sent_height = 0 :: non_neg_integer(),
    sample_rate :: float(),
    pubkey :: binary(),
    sigfun :: function(),
    mref = undefined :: undefined | reference(),
    always_send = false :: boolean()
}).

toggle_always_send() ->
    gen_server:call(?MODULE, toggle_always_send).

log(Metadata, Msg) ->
    gen_server:cast(?MODULE, {log, Metadata, Msg}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = blockchain_event:add_handler(self()),
    lager_app:start_handler(lager_event, miner_lager_telemetry_backend, [{level, none}]),
    Rate = application:get_env(miner, telemetry_sample_rate, 0.1),
    Modules = [
        miner_hbbft_handler,
        libp2p_group_relcast_server,
        miner_consensus_mgr,
        miner_dkg_handler,
        miner
    ],
    Traces = [
        begin
            {ok, T} = lager:trace(miner_lager_telemetry_backend, [{module, Module}], debug),
            T
        end
     || Module <- Modules
    ],
    {ok, {PubKey, SigFun}} = miner:keys(),
    {ok, #state{traces = Traces, sample_rate = Rate, pubkey = PubKey, sigfun = SigFun}}.

handle_info({'DOWN', Mref, process, Pid, Reason}, #state{ mref = undefined } = State) ->
    lager:warning("Got ~p exit from http pid ~p, monitor reference ~p before monitor reference was stored", [Reason, Pid, Mref]),
    {noreply, State#state{ mref = undefined }};
handle_info({'DOWN', Mref, process, _Pid, normal}, #state{ mref = Mref } = State) ->
    lager:info("Got normal exit from http process"),
    {noreply, State#state{ mref = undefined }};
handle_info({'DOWN', Mref, process, _Pid, Reason}, #state{ mref = Mref } = State) ->
    lager:error("http request exited with ~p", [Reason]),
    {noreply, State#state{ mref = undefined }};
%% Normally we will collect and emit telemetry every block, but when
% a node is in consensus, we will send telemetry more frequently
%%
%% (Currently every 30 seconds)
handle_info({blockchain_event, {add_block, _Hash, _Sync, Ledger}}, State) ->
    %% cancel any timers from the previous block
    erlang:cancel_timer(State#state.timer),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    BinPubKey = libp2p_crypto:pubkey_to_bin(State#state.pubkey),
    Data0 = #{
        id => ?BIN_TO_B58(BinPubKey),
        name => ?BIN_TO_ANIMAL(BinPubKey),
        height => Height,
        version => miner:version(),
        logs => lists:reverse(State#state.logs),
        counts => State#state.counts
    },
    InConsensus = try
                      miner_consensus_mgr:in_consensus()
                  catch
                      _:_ ->
                          false
                  end,
    {Timer, NewData} =
        case InConsensus of
            true ->
                Status = miner:hbbft_status(),
                Queue = miner:relcast_queue(consensus_group),
                %% pull telemetry again in 30s
                T = erlang:send_after(?CONSENSUS_TELEMETRY_INTERVAL, self(), telemetry_timeout),
                {T, Data0#{
                    hbbft => #{
                        status => Status,
                        queue => format_hbbft_queue(Queue)
                              }
                     }
                };
            false ->
                {make_ref(), Data0}
        end,
    NewState = maybe_send_telemetry(NewData, InConsensus, Height, State),
    {noreply, NewState#state{timer = Timer}};
handle_info(telemetry_timeout, State) ->
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger()),
    Id = libp2p_crypto:pubkey_to_bin(State#state.pubkey),
    Status = miner:hbbft_status(),
    Queue = miner:relcast_queue(consensus_group),
    NewState = maybe_send_telemetry(
        #{
            id => ?BIN_TO_B58(Id),
            name => ?BIN_TO_ANIMAL(Id),
            height => Height,
            version => miner:version(),
            logs => lists:reverse(State#state.logs),
            counts => State#state.counts,
            hbbft => #{
                status => Status,
                queue => format_hbbft_queue(Queue)
            }
        },
        true,
        Height,
        State
    ),
    %% pull telemetry again in 30s
    Timer = erlang:send_after(30000, self(), telemetry_timeout),
    {noreply, NewState#state{timer = Timer}};
handle_info(Msg, State) ->
    lager:info("unhandled info ~p", [Msg]),
    {noreply, State}.

handle_call(toggle_always_send, _From, #state{ always_send = AS } = State) ->
    NewAS = not AS,
    {reply, {always_send, NewAS}, State#state{ always_send = NewAS }};
handle_call(Msg, From, State) ->
    lager:info("unhandled call ~p from ~p", [Msg, From]),
    {reply, diediedie, State}.

handle_cast({log, Metadata, Msg}, State = #state{sample_rate = R, counts = C, logs = Logs}) ->
    %% we will only collect a sample of the log messages, but we will count _all_ of the
    %% log messages.
    NewLogs =
        case rand:uniform() =< R of
            true -> [Msg | Logs];
            false -> Logs
        end,
    Severity = get_metadata(severity, Metadata),
    Module = get_metadata(module, Metadata),
    {Line, _Col} = get_metadata(line, Metadata, {0, 0}),

    %% We want to end up with a data structure that looks like
    %% #{ Module => #{ Severity => #{ LineNum => Count } } }
    %% This will make it easier to serialize to JSON and to
    %% handle it when we get it on the other side of the HTTP connection
    NewCounts = maps:update_with(
        Module,
        fun(M) ->
            maps:update_with(
                Severity,
                fun(V) ->
                    maps:update_with(
                        Line,
                        fun(Cnt) -> Cnt + 1 end,
                        1,
                        V
                    )
                end,
                #{Line => 1},
                M
            )
        end,
        #{Severity => #{Line => 1}},
        C
    ),
    {noreply, State#state{counts = NewCounts, logs = NewLogs}};
handle_cast(Msg, State) ->
    lager:info("unhandled cast ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    [lager:stop_trace(Trace) || Trace <- State#state.traces],
    ok.

maybe_send_telemetry(Json, _InConsensus, Height,
                     #state{ always_send = true, sigfun = SigFun } = State) ->
    case application:get_env(miner, telemetry_url) of
        {ok, URL} ->
            {_Pid, Mref} = do_send(URL, Json, SigFun),
            State#state{mref = Mref, logs = [], counts = #{},
                        last_sent_height=Height};
        _ ->
            lager:warning("telemetry always_send is true, but no url is specified. not sending"),
            State#state{logs = [], counts = #{}}
    end;
maybe_send_telemetry(Json, true, Height, #state{sigfun = SigFun} = State) ->
    case application:get_env(miner, telemetry_url) of
        {ok, URL} ->
            {_Pid, Mref} = do_send(URL, Json, SigFun),
            State#state{mref = Mref, logs = [],
                        counts = #{}, last_sent_height = Height};
        _ ->
            State#state{logs = [], counts = #{}}
    end;
maybe_send_telemetry(Json, false, Height,
                     #state{last_sent_height=Last, sigfun=SigFun} = State) ->
    case application:get_env(miner, telemetry_url) of
        {ok, URL} ->
            case (Height - Last) >= ?TELEMETRY_SEND_INTERVAL andalso
                 rand:uniform() >= 0.50 of
                true ->
                    {_Pid, Mref} = do_send(URL, Json, SigFun),
                    State#state{mref = Mref, logs = [],
                                counts = #{}, last_sent_height = Height};
                false ->
                    State
            end;
        _ -> State
    end.

do_send(URL, #{ height := Height, version := Version, id := Id } = Json, SigFun) ->
    Compressed = zlib:gzip(jsx:encode(Json)),
    Signature = SigFun(Compressed),
    spawn_monitor(fun() -> send_telemetry(Compressed, Signature, Id, Height, Version, URL)
                  end).

get_metadata(Key, M) ->
    get_metadata(Key, M, undefined).

get_metadata(Key, M, Default) ->
    case lists:keyfind(Key, 1, M) of
        {Key, Value} -> Value;
        false -> Default
    end.

send_telemetry(Data, Signature, Id, Height, Version, URL) ->
    {ok, {Status, _Body}} = httpc:request(
            post,
            {URL,
                    [
                        {"X-Telemetry-Signature", base64url:encode(Signature)},
                        {"X-Telemetry-Miner-Id", Id},
                        {"X-Telemetry-Wallclock-Sent", integer_to_list(erlang:system_time(seconds))},
                        {"X-Telemetry-Height", integer_to_list(Height)},
                        {"X-Telemetry-Miner-Version", integer_to_list(Version)},
                        {"User-Agent", "miner-telemetry-1"},
                        {"Content-Encoding", "gzip"}
                    ],
                    "application/json", Data},
                [{timeout, 30000}],
                [{body_format, binary}, {full_result, false}]
           ),
    lager:info("Got status ~p from ~p", [Status, URL]),
    ok.

%% copy-pasta'd from miner_jsonrpc_hbbft
format_hbbft_queue(Queue) ->
    #{
        inbound := Inbound,
        outbound := Outbound
    } = Queue,
    Workers = miner:relcast_info(consensus_group),
    Outbound1 = maps:map(
        fun(K, V) ->
            #{
                address := Raw,
                connected := Connected,
                ready := Ready,
                in_flight := InFlight,
                connects := Connects,
                last_take := LastTake,
                last_ack := LastAck
            } = maps:get(K, Workers),
            #{
                address => ?BIN_TO_B58(Raw),
                name => ?BIN_TO_ANIMAL(Raw),
                count => length(V),
                connected => Connected,
                blocked => not Ready,
                in_flight => InFlight,
                connects => Connects,
                last_take => LastTake,
                last_ack => erlang:system_time(seconds) - LastAck
            }
        end,
        Outbound
    ),
    #{
        inbound => length(Inbound),
        outbound => Outbound1
    }.
