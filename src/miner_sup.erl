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

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 15000,
    type => worker,
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

    BaseDir = application:get_env(blockchain, base_dir, "data"),

    ok = libp2p_crypto:set_network(application:get_env(miner, network, mainnet)),

    ChildSpecs =
        [
         ?SUP(miner_gateway_sup, []),
         ?SUP(miner_critical_sup, []),
         ?SUP(miner_restart_sup, [])
        ],
    {ok, {SupFlags, ChildSpecs}}.
