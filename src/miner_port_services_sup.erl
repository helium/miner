%%%-------------------------------------------------------------------
%% @doc miner external port components supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_port_services_sup).

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

            KeyPair =
                case application:get_env(miner, gateway_keypair) of
                    undefined ->
                        code:priv_dir(miner) ++ "/gateway_rs/gateway_key.bin";
                    {ok, {ecc, Keypair}} ->
                        Keypair;
                    {ok, {file, File}} ->
                        filename:absname(File)
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

            MuxOpts = [
                {host_port, application:get_env(miner, mux_host_port, 1680)},
                {client_ports, application:get_env(miner, mux_client_ports, [1681, 1682])}
            ],

            ChildSpecs =
                [
                    ?WORKER(miner_gateway_port, [GatewayPortOpts]),
                    ?WORKER(miner_gateway_ecc_worker, [GatewayECCWorkerOpts]),
                    ?WORKER(miner_mux_port, [MuxOpts])
                ],

            {ok, {SupFlags, ChildSpecs}};
        _ ->
            ignore
    end.
