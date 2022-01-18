%%%-------------------------------------------------------------------
%% @doc miner Gateway-rs component supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_gateway_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

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
    supervisor:start_link({local, ?MODULE}, ?MODULE, [[]]).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init(_Opts) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 0,
        period => 1
    },

    GatewayECCWorkerOpts = [
        {transport, application:get_env(miner, gateway_worker_transport, tcp)},
        {host, application:get_env(miner, gateway_worker_host, "localhost")},
        {port, application:get_env(miner, gateway_worker_port, 44670)}
    ],

    ChildSpecs =
        [
         ?WORKER(miner_gateway_port, []),
         ?WORKER(miner_gateway_ecc_worker, [GatewayECCWorkerOpts])
        ],

    {ok, {SupFlags, ChildSpecs}}.
