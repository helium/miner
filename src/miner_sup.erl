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
    SupFlags = #{strategy => rest_for_one
                 ,intensity => 1
                 ,period => 5},

    %% Blockchain Supervisor Options
    SeedNodes = case application:get_env(blockchain, seed_nodes) of
                    {ok, ""} -> [];
                    {ok, Seeds} -> string:split(Seeds, ",", all);
                    _ -> []
                end,
    Port = application:get_env(blockchain, port, 0),
    NumConsensusMembers = application:get_env(blockchain, num_consensus_members, 7),
    BaseDir = application:get_env(blockchain, base_dir, "data"),

    SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    {PublicKey, SigFun} = case libp2p_crypto:load_keys(SwarmKey) of
                              {ok, PrivKey, PubKey} ->
                                  {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)};
                              {error, enoent} ->
                                  {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
                                  ok = libp2p_crypto:save_keys({PrivKey, PubKey}, SwarmKey),
                                  {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)}
                          end,

    BlockchainOpts = [
                      {key, {PublicKey, SigFun}}
                      ,{seed_nodes, SeedNodes}
                      ,{port, Port}
                      ,{num_consensus_members, NumConsensusMembers}
                      ,{base_dir, BaseDir}
                     ],

    %% Miner Options
    Curve = application:get_env(miner, curve, 'SS512'),
    BlockTime = application:get_env(miner, block_time, 15000),
    BatchSize = application:get_env(miner, batch_size, 500),
    RadioDevice = application:get_env(miner, radio_device, undefined),
    GPSDevice = application:get_env(miner, gps_device, undefined),

    MinerOpts = [
                 {curve, Curve}
                 ,{block_time, BlockTime}
                 ,{batch_size, BatchSize}
                 ,{radio_device, RadioDevice}
                 ,{gps_device, GPSDevice}
                ],

    ChildSpecs =  [#{id => blockchain_sup
                     ,start => {blockchain_sup, start_link, [BlockchainOpts]}
                     ,restart => permanent
                     ,type => supervisor
                    },
                   #{id => miner
                     ,start => {miner, start_link, [MinerOpts]}
                     ,restart => permanent
                     ,type => worker
                     ,modules => [miner]}],

    {ok, {SupFlags, ChildSpecs}}.
