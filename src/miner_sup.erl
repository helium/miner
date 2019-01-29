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
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
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
        intensity => 10,
        period => 10
    },

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

    case application:get_env(blockchain, key, undefined) of
        undefined ->
            SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
            ok = filelib:ensure_dir(SwarmKey),
            {PublicKey, ECDHFun, SigFun} =
                case libp2p_crypto:load_keys(SwarmKey) of
                    {ok, #{secret := PrivKey0, public := PubKey}} ->
                        {PubKey, libp2p_crypto:mk_ecdh_fun(PrivKey0), libp2p_crypto:mk_sig_fun(PrivKey0)};
                    {error, enoent} ->
                        KeyMap = #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
                        ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                        {PubKey, libp2p_crypto:mk_ecdh_fun(PrivKey0), libp2p_crypto:mk_sig_fun(PrivKey0)}
                end;
        {PublicKey, ECDHFun, SigFun} ->
            ok
    end,

    BlockchainOpts = [
        {key, {PublicKey, SigFun}},
        {seed_nodes, SeedNodes ++ SeedAddresses},
        {max_inbound_connections, MaxInboundConnections},
        {port, Port},
        {num_consensus_members, NumConsensusMembers},
        {base_dir, BaseDir},
        {update_dir, application:get_env(miner, update_dir, undefined)}
    ],

    %% Miner Options
    Curve = application:get_env(miner, curve, 'SS512'),
    BlockTime = application:get_env(miner, block_time, 15000),
    BatchSize = application:get_env(miner, batch_size, 500),
    RadioDevice = application:get_env(miner, radio_device, undefined),

    MinerOpts =
        [
         {curve, Curve},
         {block_time, BlockTime},
         {batch_size, BatchSize},
         {radio_device, RadioDevice},
         {election_interval, application:get_env(miner, election_interval, 30)}
        ],

    POCOpts = #{},

    OnionServer =
        case application:get_env(miner, radio_device, undefined) of
            {RadioHost, RadioPort} ->
                OnionOpts = #{
                    radio_host => RadioHost,
                    radio_port => RadioPort,
                    ecdh_fun => ECDHFun
                },
                [?WORKER(miner_onion_server, [OnionOpts])];
            _ ->
                []
        end,

    EbusServer =
        case application:get_env(miner, use_ebus, false) of
            true -> [?WORKER(miner_ebus, [])];
            _ -> []
        end,

    ChildSpecs =  [
        ?SUP(blockchain_sup, [BlockchainOpts]),
        ?WORKER(miner, [MinerOpts]),
        ?WORKER(miner_poc_statem, [POCOpts])
    ] ++ EbusServer ++ OnionServer,
    {ok, {SupFlags, ChildSpecs}}.
