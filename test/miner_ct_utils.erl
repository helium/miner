-module(miner_ct_utils).

-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-export([pmap/2, pmap/3,
         wait_until/1,
         wait_until/3,
         wait_until_disconnected/2,
         start_node/3,
         partition_cluster/2,
         heal_cluster/2,
         connect/1,
         count/2,
         randname/1,
         get_config/2,
         random_n/2,
         init_per_testcase/2,
         end_per_testcase/2,
         get_balance/2,
         make_vars/1, make_vars/2, make_vars/3,
         tmp_dir/0, tmp_dir/1, nonl/1
        ]).

pmap(F, L) ->
    pmap(F, L, timer:seconds(90)).

pmap(F, L, Timeout) ->
    Parent = self(),
    lists:foldl(
      fun(X, N) ->
              spawn_link(fun() ->
                                 Parent ! {pmap, N, F(X)}
                         end),
              N+1
      end, 0, L),
    Ref = erlang:send_after(Timeout, self(), boom),
    L2 = [receive
              {pmap, N, R} ->
                  {N,R};
              boom ->
                  error(timeout_expired)
          end || _ <- L],
    erlang:cancel_timer(Ref),
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    L3.

wait_until(Fun) ->
    wait_until(Fun, 40, 100).
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    try Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    catch _:_ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

wait_until_offline(Node) ->
    wait_until(fun() ->
                       pang == net_adm:ping(Node)
               end, 60*2, 500).

wait_until_disconnected(Node1, Node2) ->
    wait_until(fun() ->
                       pang == rpc:call(Node1, net_adm, ping, [Node2])
               end, 60*2, 500).

wait_until_connected(Node1, Node2) ->
    wait_until(fun() ->
                       pong == rpc:call(Node1, net_adm, ping, [Node2])
               end, 60*2, 500).

start_node(Name, Config, Case) ->
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path()),
    %% have the slave nodes monitor the runner node, so they can't outlive it
    NodeConfig = [
                  {monitor_master, true},
                  {startup_functions, [
                                       {code, set_path, [CodePath]}
                                      ]}],

    case ct_slave:start(Name, NodeConfig) of
        {ok, Node} ->
            ok = wait_until(fun() ->
                                    net_adm:ping(Node) == pong
                            end, 60, 500),
            Node;
        {error, already_started, Node} ->
            ct_slave:stop(Name),
            wait_until_offline(Node),
            start_node(Name, Config, Case);
        {error, started_not_connected, Node} ->
            connect(Node),
            ct_slave:stop(Name),
            wait_until_offline(Node),
            start_node(Name, Config, Case)
    end.

partition_cluster(ANodes, BNodes) ->
    pmap(fun({Node1, Node2}) ->
                 true = rpc:call(Node1, erlang, set_cookie, [Node2, canttouchthis]),
                 true = rpc:call(Node1, erlang, disconnect_node, [Node2]),
                 ok = wait_until_disconnected(Node1, Node2)
         end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

heal_cluster(ANodes, BNodes) ->
    GoodCookie = erlang:get_cookie(),
    pmap(fun({Node1, Node2}) ->
                 true = rpc:call(Node1, erlang, set_cookie, [Node2, GoodCookie]),
                 ok = wait_until_connected(Node1, Node2)
         end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

connect(Node) ->
    connect(Node, true).

connect(NodeStr, Auto) when is_list(NodeStr) ->
    connect(erlang:list_to_atom(lists:flatten(NodeStr)), Auto);
connect(Node, Auto) when is_atom(Node) ->
    connect(node(), Node, Auto).

connect(Node, Node, _) ->
    {error, self_join};
connect(_, Node, _Auto) ->
    attempt_connect(Node).

attempt_connect(Node) ->
    case net_kernel:connect_node(Node) of
        false ->
            {error, not_reachable};
        true ->
            {ok, connected}
    end.

count(_, []) -> 0;
count(X, [X|XS]) -> 1 + count(X, XS);
count(X, [_|XS]) -> count(X, XS).

randname(N) ->
    randname(N, []).

randname(0, Acc) ->
    Acc;
randname(N, Acc) ->
    randname(N - 1, [rand:uniform(26) + 96 | Acc]).

get_config(Arg, Default) ->
    case os:getenv(Arg, Default) of
        false -> Default;
        T when is_list(T) -> list_to_integer(T);
        T -> T
    end.

random_n(N, List) ->
    lists:sublist(shuffle(List), N).

shuffle(List) ->
    [x || {_,x} <- lists:sort([{rand:uniform(), N} || N <- List])].

init_per_testcase(TestCase, Config) ->
    os:cmd(os:find_executable("epmd")++" -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner-miner" ++
                                        integer_to_list(erlang:system_time(nanosecond)) ++
                                        "@"++Hostname), shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, {{already_started, _},_}} -> ok
    end,

    %% Miner configuration, can be input from os env
    TotalMiners =
        case TestCase of
            restart_test ->
                4;
            _ ->
                get_config("T", 8)
        end,
    NumConsensusMembers =
        case TestCase of
            group_change_test ->
                4;
            restart_test ->
                4;
            _ ->
                get_config("N", 7)
        end,
    SeedNodes = [],
    Port = get_config("PORT", 0),
    Curve = 'SS512',
    BlockTime = get_config("BT", 100),
    BatchSize = get_config("BS", 500),
    Interval = get_config("INT", 5),

    MinersAndPorts = miner_ct_utils:pmap(
        fun(I) ->
            MinerName = list_to_atom(integer_to_list(I) ++ miner_ct_utils:randname(5)),
            {miner_ct_utils:start_node(MinerName, Config, miner_dist_SUITE), {45000, 46000+I}}
        end,
        lists:seq(1, TotalMiners)
    ),

    Keys = miner_ct_utils:pmap(
             fun({Miner, Ports}) ->
                     Pid = miner_ct_utils:start_node(Miner, Config, miner_dist_SUITE),
                     #{secret := GPriv, public := GPub} =
                     libp2p_crypto:generate_keys(ecc_compact),
                     GECDH = libp2p_crypto:mk_ecdh_fun(GPriv),
                     GAddr = libp2p_crypto:pubkey_to_bin(GPub),
                     GSigFun = libp2p_crypto:mk_sig_fun(GPriv),
                     {Miner, Ports, Pid, GECDH, GPub, GAddr, GSigFun}
             end, MinersAndPorts),

    ConfigResult = miner_ct_utils:pmap(
        fun({_MinerName, {TCPPort, UDPPort}, Miner, ECDH, PubKey, _Addr, SigFun}) ->
            ct_rpc:call(Miner, cover, start, []),
            ct_rpc:call(Miner, application, load, [lager]),
            ct_rpc:call(Miner, application, load, [miner]),
            ct_rpc:call(Miner, application, load, [blockchain]),
            ct_rpc:call(Miner, application, load, [libp2p]),
            %% give each miner its own log directory
            LogRoot = "log/" ++ atom_to_list(TestCase) ++ "/" ++ atom_to_list(Miner),
            ct_rpc:call(Miner, application, set_env, [lager, log_root, LogRoot]),
            %% set blockchain configuration
            Key = {PubKey, ECDH, SigFun, undefined},
            BaseDir = "data_" ++ atom_to_list(TestCase) ++ "_" ++ atom_to_list(Miner),
            ct_rpc:call(Miner, application, set_env, [blockchain, base_dir, BaseDir]),
            ct_rpc:call(Miner, application, set_env, [blockchain, port, Port]),
            ct_rpc:call(Miner, application, set_env, [blockchain, seed_nodes, SeedNodes]),
            ct_rpc:call(Miner, application, set_env, [blockchain, key, Key]),
            ct_rpc:call(Miner, application, set_env, [blockchain, peer_cache_timeout, 30000]),
            ct_rpc:call(Miner, application, set_env, [blockchain, peerbook_update_interval, 200]),

            %% set miner configuration
            ct_rpc:call(Miner, application, set_env, [miner, curve, Curve]),
            ct_rpc:call(Miner, application, set_env, [miner, radio_device, {{127,0,0,1}, UDPPort, {127,0,0,1}, TCPPort}]),

            {ok, _StartedApps} = ct_rpc:call(Miner, application, ensure_all_started, [miner]),
            ok
        end,
        Keys
    ),

    Miners = [M || {M, _} <- MinersAndPorts],
    %% check that the config loaded correctly on each miner
    true = lists:all(
        fun(ok) -> true;
        (Res) ->
            ct:pal("config setup failure: ~p", [Res]),
            false
        end,
        ConfigResult
    ),

    Addrs = miner_ct_utils:pmap(
              fun(Miner) ->
                      Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 2000),
                      [H|_] = ct_rpc:call(Miner, libp2p_swarm, listen_addrs, [Swarm], 2000),
                      H
              end, Miners),

    miner_ct_utils:pmap(
      fun(Miner) ->
              Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 2000),
              lists:foreach(
                fun(A) ->
                        ct_rpc:call(Miner, libp2p_swarm, connect, [Swarm, A], 2000)
                end, Addrs)
      end, Miners),

    %% accumulate the address of each miner
    Addresses = lists:foldl(
        fun(Miner, Acc) ->
            Address = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
            [Address | Acc]
        end,
        [],
        Miners
    ),
    {ok, _} = ct_cover:add_nodes(Miners),
    [
        {miners, Miners},
        {keys, Keys},
        {ports, MinersAndPorts},
        {addresses, Addresses},
        {block_time, BlockTime},
        {batch_size, BatchSize},
        {dkg_curve, Curve},
        {election_interval, Interval},
        {num_consensus_members, NumConsensusMembers}
        | Config
    ].

end_per_testcase(_TestCase, Config) ->
    Miners = proplists:get_value(miners, Config),
    miner_ct_utils:pmap(fun(Miner) -> ct_slave:stop(Miner) end, Miners),
    {comment, done}.

get_balance(Miner, Addr) ->
    Chain = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    Ledger = ct_rpc:call(Miner, blockchain, ledger, [Chain]),
    {ok, Entry} = ct_rpc:call(Miner, blockchain_ledger_v1, find_entry, [Addr, Ledger]),
    ct_rpc:call(Miner, blockchain_ledger_entry_v1, balance, [Entry]).

make_vars(Keys) ->
    make_vars(Keys, #{}).

make_vars(Keys, Map) ->
    make_vars(Keys, Map, modern).

make_vars(Keys, Map, Mode) ->
    Vars1 = #{?chain_vars_version => 2,
              ?block_time => 1,
              ?election_interval => 30,
              ?election_restart_interval => 10,
              ?num_consensus_members => 7,
              ?batch_size => 2500,
              ?vars_commit_delay => 5,
              ?var_gw_inactivity_threshold => 20,
              ?block_version => v1,
              ?dkg_curve => 'SS512',
              ?predicate_callback_mod => miner,
              ?predicate_callback_fun => test_version,
              ?predicate_threshold => 0.85,
              ?monthly_reward => 50000 * 1000000,
              ?securities_percent => 0.35,
              ?dc_percent => 0,
              ?poc_challengees_percent => 0.19 + 0.16,
              ?poc_challengers_percent => 0.09 + 0.06,
              ?poc_witnesses_percent => 0.02 + 0.03,
              ?consensus_percent => 0.10,
              ?election_selection_pct => 60,
              ?election_replacement_factor => 4,
              ?election_replacement_slope => 20,
              ?min_score => 0.2,
              ?alpha_decay => 0.007,
              ?beta_decay => 0.0005,
              ?max_staleness => 100000,
              ?min_assert_h3_res => 12,
              ?h3_neighbor_res => 12,
              ?h3_max_grid_distance => 13,
              ?h3_exclusion_ring_dist => 2,
              ?poc_challenge_interval => 10%% ,
              %% ?poc_path_limit => 7
             },

    #{secret := Priv, public := Pub} = Keys,
    BinPub = libp2p_crypto:pubkey_to_bin(Pub),

    Vars = maps:merge(Vars1, Map),
        case Mode of
            modern ->
                Txn = blockchain_txn_vars_v1:new(Vars, 1, #{master_key => BinPub}),
                Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
                [blockchain_txn_vars_v1:key_proof(Txn, Proof)];
            %% in legacy mode, we have to do without some stuff
            %% because everything will break if there are too many vars
            legacy ->
                %% ideally figure out a few more that are safe to
                %% remove or bring back the splitting code
                LegVars = maps:without([poc_path_limit, ?chain_vars_version, ?block_version],
                                       Vars),
                Proof = blockchain_txn_vars_v1:legacy_create_proof(Priv, LegVars),
                Txn = blockchain_txn_vars_v1:new(LegVars, 1, #{master_key => BinPub,
                                                            key_proof => Proof}),

                [Txn]

        end.

tmp_dir() ->
    ?MODULE:nonl(os:cmd("mktemp -d")).

tmp_dir(Dir) ->
    filename:join(tmp_dir(), Dir).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].