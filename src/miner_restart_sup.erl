%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_restart_sup).

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
    supervisor:start_link({local, ?MODULE}, ?MODULE, [[]]).

%% ------------------------------------------------------------------
%% Supervisor callbacks
%% ------------------------------------------------------------------
init(_Opts) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 4,
        period => 10
    },

    #{ ecdh_fun := ECDHFun,
       sig_fun := SigFun
     } = miner_keys:keys(),

    BaseDir = application:get_env(blockchain, base_dir, "data"),

    %% Miner Options

    OnionOpts =
        case application:get_env(miner, radio_device, undefined) of
            {RadioBindIP, RadioBindPort0, RadioSendIP, RadioSendPort} ->
                RadioBindPort =
                    case application:get_env(miner, gateway_and_mux_enable, false) of
                        false -> RadioBindPort0;
                        true -> RadioBindPort0 + 1
                    end,
                %% check if we are overriding/forcing the region ( for lora )
                RegionOverRide = check_for_region_override(),
                #{
                    radio_udp_bind_ip => RadioBindIP,
                    radio_udp_bind_port => RadioBindPort,
                    radio_udp_send_ip => RadioSendIP,
                    radio_udp_send_port => RadioSendPort,
                    ecdh_fun => ECDHFun,
                    sig_fun => SigFun,
                    region_override => RegionOverRide
                };
            _ ->
                #{
                  radio_udp_bind_ip => {127, 0, 0, 1},
                  radio_udp_bind_port => 0,
                  ecdh_fun => ECDHFun,
                  sig_fun => SigFun
                 }
        end,

    EbusServer =
        case application:get_env(miner, use_ebus, false) of
            true -> [?WORKER(miner_ebus, [])];
            _ -> []
        end,

    MinerMode = application:get_env(miner, mode, gateway),
    POCServers =
        case MinerMode of
            validator ->
                %% core and sibyl need to callback to miner_poc_mgr
                %% and so we need to set an env var to let it know the mod name
                application:set_env(blockchain, poc_mgr_mod, miner_poc_mgr),
                application:set_env(sibyl, poc_mgr_mod, miner_poc_mgr),
                application:set_env(sibyl, poc_report_handler, miner_poc_report_handler),
                POCOpts = #{base_dir => BaseDir,
                            cfs => ["default",
                                    "local_poc_cf",
                                    "local_poc_keys_cf"
                                   ]
                           },
                {ok, PoCCache} = cream:new(1000),
                persistent_term:put(poc_cache, PoCCache),
                [
                    ?WORKER(miner_poc_mgr_db_owner, [POCOpts]),
                    ?WORKER(miner_poc_mgr, [])
                ];
            gateway ->
                %% running as a gateway
                %% run both the grpc and libp2p version of the lora & onion modules
                %% they will work out which is required based on chain vars
                %% start miner_poc_statem, if the pocs are being run by validators, it will do nothing
                %% start the grpc start client, if the pocs are NOT being run by validators, it will do nothing
                POCOpts = #{
                    base_dir => BaseDir
                   },
                {ok, ClientStateMTab} = miner_poc_grpc_client_statem:make_ets_table(),
                ClientStateMOpts = #{
                    tab => ClientStateMTab
                },
                [
                    ?WORKER(miner_onion_server_light, [OnionOpts]),
                    ?WORKER(miner_onion_server, [OnionOpts]),
                    ?WORKER(miner_lora_light, [OnionOpts]),
                    ?WORKER(miner_lora, [OnionOpts]),
                    ?WORKER(miner_poc_grpc_client_statem, [ClientStateMOpts]),
                    ?WORKER(miner_poc_statem, [POCOpts])

                ]
        end,

    {JsonRpcPort, JsonRpcIp} = jsonrpc_server_config(),
    ValServers =
        case MinerMode of
            validator ->
                [
                    ?WORKER(miner_val_heartbeat, []),
                    ?SUP(sibyl_sup, [])
                ];
            _ ->
                []
        end,

    ChildSpecs =

        [
         ?WORKER(miner_hbbft_sidecar, []),
         ?WORKER(miner, []),
         ?WORKER(elli, [[{callback, miner_jsonrpc_handler},
                         {ip, JsonRpcIp},
                         {port, JsonRpcPort}]]),
         ?WORKER(miner_poc_denylist, [])
         ] ++
        POCServers ++
        ValServers ++
        EbusServer,
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

-ifdef(TEST).
jsonrpc_server_config() ->
    %% choose a random high port above the grpc port
    JsonRpcPort = rand:uniform(40000)+10000,
    %% lookup the port in case it's set
    JsonRpcPort0 = application:get_env(miner, jsonrpc_port, JsonRpcPort),
    %% maybe set it so we can easily get the port number during a test if needed
    %%
    %% if it's already set, it shouldn't match the random port number, so don't
    %% do anything in that case.
    case JsonRpcPort0 of
        JsonRpcPort -> application:set_env(miner, jsonrpc_port, JsonRpcPort);
        _ -> ok
    end,
    JsonRpcIp = application:get_env(miner, jsonrpc_ip, {127,0,0,1}),
    {JsonRpcPort0, JsonRpcIp}.
-else.
jsonrpc_server_config() ->
    JsonRpcPort = application:get_env(miner, jsonrpc_port, 4467),
    JsonRpcIp = application:get_env(miner, jsonrpc_ip, {127,0,0,1}),
    {JsonRpcPort, JsonRpcIp}.
-endif.
