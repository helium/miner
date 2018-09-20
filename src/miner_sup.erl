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
    {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
	SeedNodes = case application:get_env(blockchain, seed_nodes) of
					{ok, ""} -> [];
					{ok, Seeds} -> string:split(Seeds, ",", all);
					_ -> []
				end,
    Port = application:get_env(blockchain, port, 0),
    NumConsensusMembers = application:get_env(blockchain, num_consensus_members, 7),
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    BlockchainOpts = [
        {key, {PubKey, SigFun}}
        ,{seed_nodes, SeedNodes}
        ,{port, Port}
        ,{num_consensus_members, NumConsensusMembers}
        ,{base_dir, BaseDir}
    ],

    %% Miner Options
    Curve = application:get_env(miner, curve, 'SS512'),
    BlockTime = application:get_env(miner, block_time, 15000),
    BatchSize = application:get_env(miner, batch_size, 500),

    MinerOpts = [
                 {curve, Curve}
                 ,{block_time, BlockTime}
                 ,{batch_size, BatchSize}
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
