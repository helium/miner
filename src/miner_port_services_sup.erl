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
    case application:get_env(miner, gateway_and_mux_enable) of
        {ok, true} ->
            SupFlags = #{
                strategy => rest_for_one,
                intensity => 0,
                period => 1
            },

            GatewayTcpPort = application:get_env(miner, gateway_api_port, 4468),

            KeyPair =
                case application:get_env(blockchain, key, undefined) of
                    undefined ->
                        BaseDir = application:get_env(blockchain, base_dir, "data"),
                        GatewayKey = filename:absname(filename:join([BaseDir, "miner", "gateway_swarm_key"])),
                        ok = filelib:ensure_dir(GatewayKey),
                        case filelib:is_file(GatewayKey) of
                            true ->
                                GatewayKey;
                            false ->
                                SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
                                case filelib:is_file(SwarmKey) of
                                    true ->
                                        {ok, KeyMap} = libp2p_crypto:load_keys(SwarmKey),
                                        {ok, GatewayKeyMap} = miner_keys:libp2p_to_gateway_key(KeyMap),
                                        ok = libp2p_crypto:save_keys(GatewayKeyMap, GatewayKey),
                                        GatewayKey;
                                    false ->
                                        Network = application:get_env(miner, network, mainnet),
                                        KeyMap = libp2p_crypto:generate_keys(Network, ecc_compact),
                                        ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                                        {ok, GatewayKeyMap} = miner_keys:libp2p_to_gateway_key(KeyMap),
                                        ok = libp2p_crypto:save_keys(GatewayKeyMap, GatewayKey),
                                        GatewayKey
                                end
                        end;
                    {ecc, Keypair0} ->
                        case io_lib:char_list(Keypair0) of
                            true -> Keypair0;
                            false -> miner_keys:key_proplist_to_uri(Keypair0)
                        end
                end,

            GatewayECCWorkerOpts = [
                {transport, application:get_env(miner, gateway_transport, tcp)},
                {host, application:get_env(miner, gateway_host, "localhost")},
                {port, GatewayTcpPort}
            ],

            GatewayPortOpts = [{keypair, KeyPair}] ++ GatewayECCWorkerOpts,

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
