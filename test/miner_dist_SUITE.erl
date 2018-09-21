-module(miner_dist_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0
        ]).

-export([initial_dkg_test/1,
         listen_addr_test/1,
         p2p_addr_test/1
        ]).

%% common test callbacks

all() -> [initial_dkg_test,
          listen_addr_test,
          p2p_addr_test
         ].

init_per_suite(Config) ->
    os:cmd(os:find_executable("epmd")++" -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@"++Hostname), shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, {{already_started, _},_}} -> ok
    end,

    %% assuming each testcase will work with 8 miners for now
    MinerNames = [eric, kenny, kyle, ike, stan, butters, timmy, jimmy],
    Miners = miner_ct_utils:pmap(fun(Miner) ->
                                        miner_ct_utils:start_node(Miner, Config, miner_dist_SUITE)
                                end, MinerNames),
    NumConsensusMembers = 7,
    SeedNodes = [],
    Port = 0,
    Curve = 'SS512',
    BlockTime = 15000,
    BatchSize = 500,

    ConfigResult = miner_ct_utils:pmap(fun(Miner) ->
                                     ct_rpc:call(Miner, cover, start, []),
                                     ct_rpc:call(Miner, application, load, [lager]),
                                     ct_rpc:call(Miner, application, load, [miner]),
                                     ct_rpc:call(Miner, application, load, [blockchain]),
                                     ct_rpc:call(Miner, application, load, [libp2p]),
                                     %% give each miner its own log directory
                                     ct_rpc:call(Miner, application, set_env, [lager, log_root, "log/"++atom_to_list(Miner)]),

                                     %% set blockchain configuration
                                     {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
                                     Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey)},
                                     BaseDir = "data_" ++ atom_to_list(Miner),
                                     ct_rpc:call(Miner, application, set_env, [blockchain, base_dir, BaseDir]),
                                     ct_rpc:call(Miner, application, set_env, [blockchain, num_consensus_members, NumConsensusMembers]),
                                     ct_rpc:call(Miner, application, set_env, [blockchain, port, Port]),
                                     ct_rpc:call(Miner, application, set_env, [blockchain, seed_nodes, SeedNodes]),
                                     ct_rpc:call(Miner, application, set_env, [blockchain, key, Key]),

                                     %% set miner configuration
                                     ct_rpc:call(Miner, application, set_env, [miner, curve, Curve]),
                                     ct_rpc:call(Miner, application, set_env, [miner, block_time, BlockTime]),
                                     ct_rpc:call(Miner, application, set_env, [miner, batch_size, BatchSize]),

                                     {ok, _StartedApps} = ct_rpc:call(Miner, application, ensure_all_started, [miner]),
                                     ct_rpc:call(Miner, lager, set_loglevel, [{lager_file_backend, "log/console.log"}, debug])
                             end, Miners),

    [{config_result, ConfigResult}, {miners, Miners}, {num_consensus_members, NumConsensusMembers} | Config].

end_per_suite(Config) ->
    Miners = proplists:get_value(miners, Config),
    miner_ct_utils:pmap(fun(Miner) -> ct_slave:stop(Miner) end, Miners),
    Config.

init_per_testcase(_TestCase, Config) ->
    ConfigResult = proplists:get_value(config_result, Config),
    Miners = proplists:get_value(miners, Config),

    %% check that the config loaded correctly on each miner
    true = lists:all(fun(Res) -> Res == ok end, ConfigResult),

    %% get the first miner's listen addrs
    [First | Rest] = Miners,
    FirstSwarm = ct_rpc:call(First, blockchain_swarm, swarm, []),
    FirstListenAddr = hd(ct_rpc:call(First, libp2p_swarm, listen_addrs, [FirstSwarm])),

    %% tell the rest of the miners to connect to the first miner
    lists:foreach(fun(Miner) ->
                          Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, []),
                          ct_rpc:call(Miner, libp2p_swarm, connect, [Swarm, FirstListenAddr])
                  end, Rest),

    %% accumulate the address of each miner
    Addresses = lists:foldl(fun(Miner, Acc) ->
                                    Address = ct_rpc:call(Miner, blockchain_swarm, address, []),
                                    [Address | Acc]
                            end, [], Miners),

    {ok, _} = ct_cover:add_nodes(Miners),
    [{addresses, Addresses} | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%% test cases
listen_addr_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    ListenAddrs = lists:foldl(fun(Miner, Acc) ->
                                      Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, []),
                                      LA = ct_rpc:call(Miner, libp2p_swarm, sessions, [Swarm]),
                                      [LA | Acc]
                              end, [], Miners),
    ct:pal("ListenAddrs: ~p", [ListenAddrs]),
    ?assertEqual(length(Miners), length(ListenAddrs)),
    ok.

p2p_addr_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    P2PAddrs = lists:foldl(fun(Miner, Acc) ->
                          Address = ct_rpc:call(Miner, blockchain_swarm, address, []),
                          P2PAddr = ct_rpc:call(Miner, libp2p_crypto, address_to_p2p, [Address]),
                          [P2PAddr | Acc]
                  end, [], Miners),
    ct:pal("P2PAddrs: ~p", [P2PAddrs]),
    ?assertEqual(length(Miners), length(P2PAddrs)),
    ok.

initial_dkg_test(Config) ->
    Miners = proplists:get_value(miners, Config),
    NumConsensusMembers = proplists:get_value(num_consensus_members, Config),
    Addresses = proplists:get_value(addresses, Config),

    DKGResults = miner_ct_utils:pmap(fun(Miner) ->
                                             ct_rpc:call(Miner, miner, initial_dkg, [Addresses])
                                     end, Miners),
    ct:pal("DKGResults: ~p", [DKGResults]),

    true = lists:all(fun(Res) -> Res == ok end, DKGResults),

    ConsensusMemberships = lists:foldl(fun(Miner, Acc) ->
                                               Res = ct_rpc:call(Miner, miner, in_consensus, []),
                                               [Res | Acc]
                                       end, [], Miners),
    ct:pal("ConsensusMemberships: ~p", [ConsensusMemberships]),

    NumConsensusMembers = miner_ct_utils:count(true, ConsensusMemberships),
    NonConsensusMember = length(Miners) - NumConsensusMembers,
    NonConsensusMember = miner_ct_utils:count(false, ConsensusMemberships),
    ok.
