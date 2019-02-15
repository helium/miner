-module(miner_plot).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         stop/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(minutes(N), N * 60).
-define(hours(N), N * ?minutes(60)).

-record(stats,
        {
         times = [] :: [integer()],
         tlens = [] :: [integer()]
        }).

-record(state,
        {
         chain :: undefined | blockchain:blockchain(),
         stats :: undefined | #stats{},
         height = 0 :: integer(),
         fd :: undefined | port()
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:call(?SERVER, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    %% timeout for async startup
    {ok, #state{}, 0}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info(timeout, _) ->
    Chain = blockchain_worker:blockchain(),
    {ok, CurrHeight} = blockchain:height(Chain),
    %% trunc any existing file for now
    {ok, File} = file:open("/tmp/miner-chain-stats", [write]),
    Infos =
        [begin
             {ok, B} = blockchain:get_block(H, Chain),
             Time = blockchain_block:time(B),
             Txns = blockchain_block:transactions(B),
             {Time, Txns}
         end
         || H <- lists:seq(1, CurrHeight)],
    %% calculate a moving average over the history of the blockchain
    %% eventually we might want to scan an existing file so we don't
    %% always have to recalculate this from the beginning.
    Stats =
        lists:foldl(
          fun(Info, Acc) ->
                  {Iolist, Acc1} = process_line(Info, Acc),
                  file:write(File, Iolist),
                  Acc1
          end,
          #stats{},
          Infos),
    ok = blockchain_event:add_handler(self()),
    {noreply, #state{chain = Chain,
                     stats = Stats,
                     height = CurrHeight,
                     fd = File}};
handle_info({blockchain_event, {add_block, Hash, _}}, #state{chain = Chain,
                                                             height = CurrHeight,
                                                             fd = File,
                                                             stats = Stats} = State) ->
    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            case blockchain_block:height(Block) of
                Height when Height > CurrHeight ->
                    Time = blockchain_block:time(Block),
                    Txns = blockchain_block:transactions(Block),
                    {Iolist, Stats1} = process_line({Time, Txns}, Stats),
                    lager:info("writing:~n ~s to dat file", [Iolist]),
                    file:write(File, Iolist),
                    {noreply, State#state{height = Height,
                                          stats = Stats1}};
                _ ->
                    {noreply, State}
            end;
        _ ->
            %% uhh
            {noreply, State}
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

truncate(New, [], _Limit) ->
    [New];
truncate(New, List, Limit) ->
    Oldest = hd(List),
    Rest = tl(List),
    case Oldest of
        0 ->
            %% stupid genesis block
            case Rest of
                [] ->
                    [Oldest, New];
                %% let's work of the stupid assumption that the
                %% genesis block is ten minutes older than the oldest block
                [Oldest1 | _] ->
                    truncate(New, [Oldest1 - ?minutes(10) | Rest], Limit)
            end;
        _ ->
            case New - Oldest >= ?minutes(Limit) of
                true ->
                    truncate(New, Rest, Limit);
                _ ->
                    List ++ [New]
            end
    end.


avg_interval([H]) ->
    H;
avg_interval([H|T]) ->
    Is = get_intervals(H, T, []),
    lists:sum(Is) div length(Is).

median_interval([H]) ->
    H;
median_interval([H|T]) ->
    case lists:sort(get_intervals(H, T, [])) of
        [I] ->
            I;
        Is ->
            Mid = length(Is) div 2,
            lists:nth(Mid, Is)
    end.

get_intervals(_Prev, [], Acc) ->
    lists:reverse(Acc);
get_intervals(Prev, [H|T], Acc) ->
    Int = H - Prev,
    get_intervals(H, T, [Int | Acc]).

process_line({0, _Txns}, Acc) ->
    {[], Acc};
process_line({Time, Txns}, #stats{times = Times0,
                                  tlens = TLens1}) ->
    TLen = length(Txns),
    TLens0 = TLens1 ++ [TLen],
    Times = truncate(Time, Times0, 120), % minutes
    {_, TLens} = lists:split(length(TLens0) - length(Times), TLens0),
    Interval =
        case Times0 of
            [] ->
                ?minutes(10);
            _ ->
                Time - lists:last(Times0)
        end,
    AvgInterval = avg_interval(Times),
    MedInterval = median_interval(Times),
    AvgTxns = lists:sum(TLens) div length(TLens),
    {[integer_to_list(Time), "\t",
      integer_to_list(Interval), "\t",
      integer_to_list(TLen), "\t",
      integer_to_list(AvgInterval), "\t",
      integer_to_list(MedInterval), "\t",
      integer_to_list(AvgTxns), "\n"],
     #stats{times = Times, tlens = TLens}}.
