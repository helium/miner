%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => infinity,
    type => supervisor,
    modules => [I]
}).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init(_Args) ->
    SupFlags = #{
                 strategy => rest_for_one,
                 intensity => 0,
                 period => 1
                },

    ChildSpecs =
        [
         ?SUP(miner_critical_sup, []),
         ?SUP(miner_restart_sup, [])
        ],
    {ok, {SupFlags, ChildSpecs}}.
