%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_critical_sup).

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
        intensity => 0,
        period => 1
    },

    #{ pubkey := PublicKey,
       key_slot := KeySlot,
       ecdh_fun := ECDHFun,
       bus := Bus,
       address := Address,
       sig_fun := SigFun
     } = miner_keys:keys(),

    %% Blockchain Supervisor Options
    SeedNodes =
        case application:get_env(blockchain, seed_nodes) of
            {ok, ""} -> [];
            {ok, Seeds} -> string:split(Seeds, ",", all);
            _ -> []
        end,
    SeedNodeDNS = application:get_env(blockchain, seed_node_dns, []),
    % look up the DNS record and add any resulting addresses to the SeedNodes
    % no need to do any checks here as any bad combination results in an empty list
    SeedAddresses = string:tokens(lists:flatten([string:prefix(X, "blockchain-seed-nodes=") || [X] <- inet_res:lookup(SeedNodeDNS, in, txt), string:prefix(X, "blockchain-seed-nodes=") /= nomatch]), ","),
    Port = application:get_env(blockchain, port, 0),
    NumConsensusMembers = application:get_env(blockchain, num_consensus_members, 4),
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    %% TODO: Remove when cuttlefish
    MaxInboundConnections = application:get_env(blockchain, max_inbound_connections, 10),

    %% downlink packets from state channels go here
    application:set_env(blockchain, sc_client_handler, miner_lora),

    BlockchainOpts = [
        {key, {PublicKey, SigFun, ECDHFun}},
        {seed_nodes, SeedNodes ++ SeedAddresses},
        {max_inbound_connections, MaxInboundConnections},
        {port, Port},
        {num_consensus_members, NumConsensusMembers},
        {base_dir, BaseDir},
        {update_dir, application:get_env(miner, update_dir, undefined)},
        {group_delete_predicate, fun miner_consensus_mgr:group_predicate/1}
    ],

    ConsensusMgr =
        case application:get_env(blockchain, follow_mode, false) of
            false ->
                [?WORKER(miner_consensus_mgr, [ignored])];
            _ ->
                []
        end,


    ChildSpecs0 = [?SUP(blockchain_sup, [BlockchainOpts])] ++ ConsensusMgr,
    GatewayAndMux = case application:get_env(miner, gateway_and_mux_enable) of
                        {ok, true} -> true;
                        _ -> false
                    end,
    ChildSpecs = case {GatewayAndMux, application:get_env(blockchain, key)} of
                     {false, {ok, {ecc, _}}} ->
                         [
                          %% Miner retains full control and responsibility for key access
                          ?WORKER(miner_ecc_worker, [KeySlot, Bus, Address])
                         ] ++ ChildSpecs0;
                     {false, {ok, {tpm, _}}} ->
                         [
                          %% Miner still retains full control and responsibility for key access;
                          %% this time in the tpm worker
                          ?WORKER(miner_tpm_worker, [KeySlot])
                         ] ++ ChildSpecs0;
                     _ ->
                         ChildSpecs0
                 end,

    {ok, {SupFlags, ChildSpecs}}.
