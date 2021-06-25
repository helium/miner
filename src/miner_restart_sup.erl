%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_restart_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

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
start_link(SigFun, ECDHFun) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [SigFun, ECDHFun]).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init([SigFun, ECDHFun]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 4,
        period => 10
    },

    %% downlink packets from state channels go here
    application:set_env(blockchain, sc_client_handler, miner_lora),

    BaseDir = application:get_env(blockchain, base_dir, "data"),
    %% Miner Options

    POCOpts = #{
                base_dir => BaseDir
               },

    OnionServer =
        case application:get_env(miner, radio_device, undefined) of
            {RadioBindIP, RadioBindPort, RadioSendIP, RadioSendPort} ->
                %% check if we are overriding/forcing the region ( for lora )
                RegionOverRide = check_for_region_override(),
                OnionOpts = #{
                    radio_udp_bind_ip => RadioBindIP,
                    radio_udp_bind_port => RadioBindPort,
                    radio_udp_send_ip => RadioSendIP,
                    radio_udp_send_port => RadioSendPort,
                    ecdh_fun => ECDHFun,
                    sig_fun => SigFun,
                    region_override => RegionOverRide
                },
                [?WORKER(miner_onion_server, [OnionOpts]),
                 ?WORKER(miner_lora, [OnionOpts]),
                 ?WORKER(miner_poc_statem, [POCOpts])];
            _ ->
                []
        end,

    EbusServer =
        case application:get_env(miner, use_ebus, false) of
            true -> [?WORKER(miner_ebus, [])];
            _ -> []
        end,

    ValServers =
        case application:get_env(miner, mode, gateway) of
            validator ->
                [?WORKER(miner_val_heartbeat, []),
                 ?SUP(sibyl_sup, [])];
            _ -> []
        end,

    JsonRpcPort = application:get_env(miner, jsonrpc_port, 4467),
    JsonRpcIp = application:get_env(miner, jsonrpc_ip, {127,0,0,1}),

    ChildSpecs =
        [
         ?WORKER(miner_hbbft_sidecar, []),
         ?WORKER(miner, []),
         ?WORKER(elli, [[{callback, miner_jsonrpc_handler},
                         {ip, JsonRpcIp},
                         {port, JsonRpcPort}]])
         ] ++
        ValServers ++
        EbusServer ++
        OnionServer,
    {ok, {SupFlags, ChildSpecs}}.


%% check if the region is being supplied to us
%% can be supplied either via the sys config or via an optional OS env var
%% with sys config taking priority if both exist
-spec check_for_region_override() -> atom().
check_for_region_override()->
    check_for_region_override(application:get_env(miner, region_override, undefined)).

-spec check_for_region_override(atom()) -> atom().
check_for_region_override(undefined)->
    case os:getenv("REGION_OVERRIDE") of
        false -> undefined;
        Region -> list_to_atom(Region)
    end;
check_for_region_override(SysConfigRegion)->
    SysConfigRegion.
