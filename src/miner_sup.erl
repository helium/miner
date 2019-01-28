%%%-------------------------------------------------------------------
%% @doc miner Supervisor
%% @end
%%%-------------------------------------------------------------------
-module(miner_sup).

-behaviour(supervisor).

-export([init/1, start_link/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

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
    NumConsensusMembers = application:get_env(blockchain, num_consensus_members, 7),
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    %% TODO: Remove when cuttlefish
    MaxInboundConnections = application:get_env(blockchain, max_inbound_connections, 10),

    SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    {PublicKey, PrivKey, SigFun} =
        case libp2p_crypto:load_keys(SwarmKey) of
            {ok, PrivKey0, PubKey} ->
                {PubKey, PrivKey0, libp2p_crypto:mk_sig_fun(PrivKey0)};
            {error, enoent} ->
                {PrivKey0, PubKey} = libp2p_crypto:generate_keys(),
                ok = libp2p_crypto:save_keys({PrivKey0, PubKey}, SwarmKey),
                {PubKey, PrivKey0, libp2p_crypto:mk_sig_fun(PrivKey0)}
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
    UseEBus = application:get_env(miner, use_ebus, false),

    MinerOpts = [
        {curve, Curve},
        {block_time, BlockTime},
        {batch_size, BatchSize},
        {radio_device, RadioDevice},
        {use_ebus, UseEBus}
    ],

    POCOpts = #{},

    {RadioHost, RadioPort} = application:get_env(miner, radio_device, {"127.0.0.1", 45000}),
    OnionOpts = #{
        radio_host => RadioHost,
        radio_port => RadioPort,
        priv_key => PrivKey
    },

    ChildSpecs =  [
        #{
            id => blockchain_sup,
            start => {blockchain_sup, start_link, [BlockchainOpts]},
            restart => permanent,
            type => supervisor
        },
        #{
            id => miner,
            start => {miner, start_link, [MinerOpts]},
            restart => permanent,
            type => worker,
            modules => [miner]
        },
        #{
            id => miner_poc_statem,
            start => {miner_poc_statem, start_link, [POCOpts]},
            restart => permanent,
            type => worker,
            modules => [miner_poc_statem]
        },
        #{
            id => miner_onion_server,
            start => {miner_onion_server, start_link, [OnionOpts]},
            restart => permanent,
            type => worker,
            modules => [miner_onion_server]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
