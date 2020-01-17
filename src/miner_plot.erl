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

-include_lib("blockchain/include/blockchain_vars.hrl").

-define(SERVER, ?MODULE).

%% in seconds
-define(minutes(N), N * 60).
-define(hours(N), N * ?minutes(60)).

%% in hours
-define(days(N), 24 * 60 * N).

%% ideal HNT / s in bones
-define(bones_per_sec, 192901234).

-record(stats,
        {
         times = [] :: [integer()],
         tlens = [] :: [integer()],
         last_rewards = 0 :: integer(),
         delay = 0 :: integer()
        }).

-record(state,
        {
         chain :: undefined | blockchain:blockchain(),
         stats :: undefined | #stats{},
         height = 0 :: integer(),
         fd :: undefined | file:io_device()
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
    erlang:process_flag(trap_exit, true),
    lager:debug("starting...",[]),
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
    {ok, Interval} = blockchain:config(?election_interval, blockchain:ledger(Chain)),
    {ok, CurrHeight} = blockchain:height(Chain),
    Start = max(1, CurrHeight - ?days(3)),
    %% trunc any existing file for now
    Filename = application:get_env(miner, stats_file, "/tmp/miner-chain-stats"),
    {ok, File} = file:open(Filename, [write]),
    Infos =
        [begin
             {ok, B} = blockchain:get_block(H, Chain),
             Time = blockchain_block:time(B),
             Txns = blockchain_block:transactions(B),
             Epoch = blockchain_block_v1:election_info(B),
             {Time, Txns, Epoch, H, Interval}
         end
         || H <- lists:seq(Start, CurrHeight)],
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
handle_info({blockchain_event, {add_block, Hash, _, Ledger}},
            #state{chain = Chain,
                   height = CurrHeight,
                   fd = File,
                   stats = Stats} = State) ->
    {ok, Interval} = blockchain:config(?election_interval, Ledger),

    case blockchain:get_block(Hash, Chain) of
        {ok, Block} ->
            case blockchain_block:height(Block) of
                Height when Height > CurrHeight ->
                    Time = blockchain_block:time(Block),
                    Txns = blockchain_block:transactions(Block),
                    Epoch = blockchain_block_v1:election_info(Block),
                    {Iolist, Stats1} = process_line({Time, Txns, Epoch, Height, Interval}, Stats),
                    lager:debug("writing:~n ~s to dat file", [Iolist]),
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
    lager:debug("terminating with reason ~p", [_Reason]),
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

avg_interval([_H]) ->
    ?minutes(2);
avg_interval([H|T]) ->
    Is = get_intervals(H, T, []),
    lists:sum(Is) div length(Is).

median_interval([_H]) ->
    ?minutes(2);
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

process_line({0, _Txns, _Epoch, _Height, _Interval}, Acc) ->
    {[], Acc};
process_line({Time, Txns, {Epoch, EpochStart}, Height, Int},
             #stats{times = Times0,
                    last_rewards = Last,
                    tlens = TLens1}) ->
    TLen = length(Txns),
    TLens0 = TLens1 ++ [TLen],
    Times = truncate(Time, Times0, 24 * 60 * 3), % two days in minutes
    {_, TLens} = lists:split(length(TLens0) - length(Times), TLens0),
    Interval =
        case Times0 of
            [] ->
                ?minutes(2);
            _ ->
                Time - lists:last(Times0)
        end,
    AvgInterval = avg_interval(Times),
    MedInterval = median_interval(Times),
    Delay = max(0, Height - (EpochStart + Int)),
    AvgTxns = lists:sum(TLens) div length(TLens),

    ConsensusDelay = extract_delay(Txns),
    {HNTRatio, Last1}  =
        case ConsensusDelay of
            "" ->
                {"", Last};
            _ ->
                Rwds = extract_rewards(Txns),
                %% count up the tokens generated
                Bones = get_bones(Rwds),
                EpochSecs = Time - Last,
                Ideal = ?bones_per_sec * EpochSecs,

                {integer_to_list(trunc( (Bones/Ideal) * 100 )),
                 Time}
        end,

    {[integer_to_list(Time), "\t",
      integer_to_list(Interval), "\t",
      integer_to_list(TLen), "\t",
      integer_to_list(AvgInterval), "\t",
      integer_to_list(MedInterval), "\t",
      integer_to_list(AvgTxns), "\t",
      integer_to_list(Height), "\t",
      float_to_list(Height / Epoch), "\t",
      integer_to_list(Delay), "\t",
      ConsensusDelay, "\t",
      HNTRatio, "\n"],
     #stats{times = Times, last_rewards = Last1, tlens = TLens}}.

extract_delay(Txns) ->
    case lists:filter(fun(T) ->
                              %% TODO: ideally move to versionless types?
                              blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                      end, Txns) of
        [Txn] ->
            integer_to_list(blockchain_txn_consensus_group_v1:delay(Txn));
        _ ->
            ""
    end.

extract_rewards(Txns) ->
    case lists:filter(fun(T) ->
                              %% TODO: ideally move to versionless types?
                              blockchain_txn:type(T) == blockchain_txn_rewards_v1
                      end, Txns) of
        [Txn] ->
            Txn
    end.

get_bones(T) ->
    Rewards = blockchain_txn_rewards_v1:rewards(T),
    lists:sum([blockchain_txn_reward_v1:amount(R) || R <- Rewards]).
