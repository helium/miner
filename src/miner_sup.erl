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
    BaseDir = "data",
    BlockchainOpts = [
        {key, {PubKey, SigFun}}
        ,{seed_nodes, []}
        ,{port, 0}
        ,{num_consensus_members, 7}
        ,{base_dir, BaseDir}
    ],

    MinerOpts = [
                 {curve, 'SS512'}
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
