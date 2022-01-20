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
    case application:get_env(blockchain, key) of
        {ok, {gateway_ecc, _}} ->
            SupFlags = #{
                strategy => rest_for_one,
                intensity => 0,
                period => 1
            },

            GatewayTcpPort = application:get_env(miner, gateway_api_port, 4468),

            KeyPair = case application:get_env(miner, gateway_keypair) of
                        undefined ->
                            code:priv_dir(miner) ++ "/gateway_rs/gateway_key.bin";
                        {ok, {Type, Keypair}} when Type == ecc orelse Type == file ->
                            Keypair
                    end,

            GatewayPortOpts = [
                {keypair, KeyPair},
                {port, GatewayTcpPort}
            ],

            GatewayECCWorkerOpts = [
                {transport, application:get_env(miner, gateway_transport, tcp)},
                {host, application:get_env(miner, gateway_host, "localhost")},
                {port, GatewayTcpPort}
            ],

            ChildSpecs =
                [
                ?WORKER(miner_gateway_port, [GatewayPortOpts]),
                ?WORKER(miner_gateway_ecc_worker, [GatewayECCWorkerOpts])
                ],

            {ok, {SupFlags, ChildSpecs}};
        _ ->
            ignore
    end.
