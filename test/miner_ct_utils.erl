-module(miner_ct_utils).

-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

-export([
         init_per_testcase/2,
         end_per_testcase/2,
         pmap/2, pmap/3,
         wait_until/1, wait_until/3,
         wait_until_disconnected/2,
         start_node/3,
         partition_cluster/2,
         heal_cluster/2,
         connect/1,
         count/2,
         randname/1,
         get_config/2,
         get_balance/2,
         make_vars/1, make_vars/2, make_vars/3,
         tmp_dir/0, tmp_dir/1, nonl/1,
         generate_keys/1,
         new_random_key/1,
         stop_miners/1, stop_miners/2,
         start_miners/1, start_miners/2,
         height/1,
         heights/1,
         consensus_members/1, consensus_members/2,
         miners_by_consensus_state/1,
         in_consensus_miners/1,
         non_consensus_miners/1,
         election_check/4,
         integrate_genesis_block/2,
         shuffle/1,
         partition_miners/2,
         node2addr/2,
         addr2node/2,
         addr_list/1,
         blockchain_worker_check/1,
         wait_for_registration/2, wait_for_registration/3,
         wait_for_app_start/2, wait_for_app_start/3,
         wait_for_app_stop/2, wait_for_app_stop/3,
         wait_for_in_consensus/2, wait_for_in_consensus/3,
         wait_for_chain_var_update/3, wait_for_chain_var_update/4,
         delete_dirs/2,
         inital_dkg/5, inital_dkg/6,
         confirm_balance/3,
         confirm_balance_both_sides/5,
         wait_for_gte/3, wait_for_gte/5


        ]).


stop_miners(Miners) ->
    stop_miners(Miners, 60).

stop_miners(Miners, Retries) ->
    [begin
          ct_rpc:call(Miner, application, stop, [miner], 300),
          ct_rpc:call(Miner, application, stop, [blockchain], 300)
     end
     || Miner <- Miners],
    ok = miner_ct_utils:wait_for_app_stop(Miners, miner, Retries),
    ok.

start_miners(Miners) ->
    start_miners(Miners, 60).

start_miners(Miners, Retries) ->
    [begin
          ct_rpc:call(Miner, application, start, [blockchain], 300),
          ct_rpc:call(Miner, application, start, [miner], 300)
     end
     || Miner <- Miners],
    ok = miner_ct_utils:wait_for_registration(Miners, blockchain_worker, Retries),
    ok.

height(Miner) ->
    C0 = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0]),
    ct:pal("miner ~p height ~p", [Miner, Height]),
    Height.

heights(Miners) ->
    lists:foldl(fun(Miner, Acc) ->
                                  C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                                  {ok, H} = ct_rpc:call(Miner, blockchain, height, [C]),
                                  [{Miner, H} | Acc]
                          end, [], Miners).

consensus_members([]) ->
    error(no_members);
consensus_members([M | Tail]) ->
    case handle_get_consensus_miners(M) of
        {ok, Members} ->
            Members;
        {error, _} ->
            timer:sleep(500),
            consensus_members(Tail)
    end.

consensus_members(Epoch, []) ->
    error({no_members_at_epoch, Epoch});
consensus_members(Epoch, [M | Tail]) ->
    try ct_rpc:call(M, miner_cli_info, get_info, [], 2000) of
        {_, _, Epoch} ->
            {ok, Members} = handle_get_consensus_miners(M),
            Members;
        Other ->
            ct:pal("~p had Epoch ~p", [M, Other]),
            timer:sleep(500),
            consensus_members(Epoch, Tail)
    catch C:E ->
            ct:pal("~p threw error ~p:~p", [M, C, E]),
            timer:sleep(500),
            consensus_members(Epoch, Tail)
    end.

miners_by_consensus_state(Miners)->
    handle_miners_by_consensus(partition, true, Miners).

in_consensus_miners(Miners)->
    handle_miners_by_consensus(filtermap, true, Miners).

non_consensus_miners(Miners)->
    handle_miners_by_consensus(filtermap, false, Miners).

election_check([], _Miners, _AddrList, Owner) ->
    Owner ! seen_all;
election_check(NotSeen0, Miners, AddrList, Owner) ->
    timer:sleep(500),
    Members = miner_ct_utils:consensus_members(Miners),
    MinerNames = lists:map(fun(Member)-> miner_ct_utils:addr2node(Member, AddrList) end, Members),
    NotSeen = NotSeen0 -- MinerNames,
    Owner ! {not_seen, NotSeen},
    election_check(NotSeen, Miners, AddrList, Owner).

integrate_genesis_block(ConsensusMiner, NonConsensusMiners)->
    Blockchain = ct_rpc:call(ConsensusMiner, blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(ConsensusMiner, blockchain, genesis_block, [Blockchain]),

    %% TODO - do we need to assert here on results from genesis load ?
    miner_ct_utils:pmap(fun(M) ->
                            ct_rpc:call(M, blockchain_worker, integrate_genesis_block, [GenesisBlock])
                        end, NonConsensusMiners).

blockchain_worker_check(Miners)->
    lists:all(
        fun(Res) ->
            Res /= undefined
        end,
        lists:foldl(
            fun(Miner, Acc) ->
                R = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
                [R | Acc]
            end, [], Miners)).

confirm_balance(Miners, Addr, Bal) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                            Bal == miner_ct_utils:get_balance(Miner, Addr)
                         end, Miners)
                 end,
        Result == true, 60, timer:seconds(1)),
    ok.

confirm_balance_both_sides(Miners, PayerAddr, PayeeAddr, PayerBal, PayeeBal) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                            PayerBal == miner_ct_utils:get_balance(Miner, PayerAddr) andalso
                            PayeeBal == miner_ct_utils:get_balance(Miner, PayeeAddr)
                         end, Miners)
                 end,
        Result == true, 60, timer:seconds(1)),
    ok.



wait_for_gte(height = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, all, 60);
wait_for_gte(epoch = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, any, 60);
wait_for_gte(height_exactly = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, all, 60).

wait_for_gte(Type, Miners, Threshold, Mod, Retries)->
    Res = ?assertAsync(begin
                     Result = lists:Mod(
                        fun(Miner) ->
                             try
                                 handle_gte_type(Type, Miner, Threshold)
                             catch _:_ ->
                                     false
                             end
                        end, miner_ct_utils:shuffle(Miners))
                 end,
        Result == true, Retries, timer:seconds(1)),

    case Res of
        true -> ok;
        false -> {error, false}
    end.

wait_for_registration(Miners, Mod) ->
    wait_for_registration(Miners, Mod, 300).
wait_for_registration(Miners, Mod, Timeout) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                             case ct_rpc:call(Miner, erlang, whereis, [Mod], Timeout) of
                                 P when is_pid(P) ->
                                     true;
                                 Other ->
                                     ct:pal("Other ~p~n", [Other]),
                                     false
                             end
                         end, Miners)
                 end,
        Result == true, 90, timer:seconds(1)),
    ok.

wait_for_app_start(Miners, App) ->
    wait_for_app_start(Miners, App, 60).
wait_for_app_start(Miners, App, Retries) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                             case ct_rpc:call(Miner, application, which_applications, []) of
                                 {badrpc, _} ->
                                     false;
                                 Apps ->
                                     lists:keymember(App, 1, Apps)
                             end
                         end, Miners)
                 end,
        Result == true, Retries, 500),
    ok.

wait_for_app_stop(Miners, App) ->
    wait_for_app_stop(Miners, App, 60).
wait_for_app_stop(Miners, App, Retries) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                             case ct_rpc:call(Miner, application, which_applications, []) of
                                 {badrpc, _} ->
                                     false;
                                 Apps ->
                                     not lists:keymember(App, 1, Apps)
                             end
                         end, Miners)
                 end,
        Result == true, Retries, 500),
    ok.



wait_for_in_consensus(Miners, NumInConsensus)->
    wait_for_in_consensus(Miners, NumInConsensus, 500).
wait_for_in_consensus(Miners, NumInConsensus, Timeout)->
    ?assertAsync(begin
                     Result = lists:filtermap(
                         fun(Miner) ->
                             C1 = ct_rpc:call(Miner, blockchain_worker, blockchain, [], Timeout),
                             L1 = ct_rpc:call(Miner, blockchain, ledger, [C1], Timeout),
                             {ok, Sz} = ct_rpc:call(Miner, blockchain, config, [num_consensus_members, L1], Timeout),
                             ct:pal("size ~p", [Sz]),
                             true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
                         end, Miners)
                 end,
        NumInConsensus == length(Result), 60, timer:seconds(1)),
    ok.

wait_for_chain_var_update(Miners, Key, Value)->
    wait_for_chain_var_update(Miners, Key, Value, 1000).
wait_for_chain_var_update(Miners, Key, Value, Timeout)->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                             C = ct_rpc:call(Miner, blockchain_worker, blockchain, [], Timeout),
                             Ledger = ct_rpc:call(Miner, blockchain, ledger, [C]),
                             {ok, Value} == ct_rpc:call(Miner, blockchain, config, [Key, Ledger], Timeout)
                         end, miner_ct_utils:shuffle(Miners))
                 end,
        Result == true, 40, timer:seconds(1)),
    ok.

delete_dirs(DirWildcard, SubDir)->
    Data = string:trim(os:cmd("pwd")),
    Dirs = filelib:wildcard(Data ++ DirWildcard),
    [begin
         ct:pal("rm dir ~s", [Dir]),
         os:cmd("rm -r " ++ Dir ++ SubDir)
     end
     || Dir <- Dirs],
    ok.

inital_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve)->
    inital_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, 12000).
inital_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, Timeout)->
    DKGResults = miner_ct_utils:pmap(
                   fun(Miner) ->
                           ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                       [Txns, Addresses, NumConsensusMembers, Curve], Timeout)
                   end, Miners),
    DKGResults.



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
            true;
        _ when Retry == 1 ->
            false;
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
            ?assertAsync(Result = net_adm:ping(Node), Result == pong, 60, 500),
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
                 true = wait_until_disconnected(Node1, Node2)
         end,
         [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]),
    ok.

heal_cluster(ANodes, BNodes) ->
    GoodCookie = erlang:get_cookie(),
    pmap(fun({Node1, Node2}) ->
                 true = rpc:call(Node1, erlang, set_cookie, [Node2, GoodCookie]),
                 true = wait_until_connected(Node1, Node2)
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

shuffle(List) ->
    R = [{rand:uniform(1000000), I} || I <- List],
    O = lists:sort(R),
    {_, S} = lists:unzip(O),
    S.



node2addr(Node, AddrList) ->
    {_, Addr} = lists:keyfind(Node, 1, AddrList),
    Addr.

addr2node(Addr, AddrList) ->
    {Node, _} = lists:keyfind(Addr, 2, AddrList),
    Node.

addr_list(Miners) ->
    miner_ct_utils:pmap(
      fun(M) ->
              Addr = ct_rpc:call(M, blockchain_swarm, pubkey_bin, []),
              {M, Addr}
      end, Miners).

partition_miners(Members, AddrList) ->
    {Miners, _} = lists:unzip(AddrList),
    lists:partition(fun(Miner) ->
                            Addr = miner_ct_utils:node2addr(Miner, AddrList),
                            lists:member(Addr, Members)
                    end, Miners).

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
                     miner_ct_utils:start_node(Miner, Config, miner_dist_SUITE),
                     #{secret := GPriv, public := GPub} =
                     libp2p_crypto:generate_keys(ecc_compact),
                     GECDH = libp2p_crypto:mk_ecdh_fun(GPriv),
                     GAddr = libp2p_crypto:pubkey_to_bin(GPub),
                     GSigFun = libp2p_crypto:mk_sig_fun(GPriv),
                     {Miner, Ports, GECDH, GPub, GAddr, GSigFun}
             end, MinersAndPorts),

    PrivDir = proplists:get_value(priv_dir, Config),

    ConfigResult = miner_ct_utils:pmap(
        fun({Miner, {TCPPort, UDPPort}, ECDH, PubKey, _Addr, SigFun}) ->
                ct:pal("Miner ~p", [Miner]),
            ct_rpc:call(Miner, cover, start, []),
            ct_rpc:call(Miner, application, load, [lager]),
            ct_rpc:call(Miner, application, load, [miner]),
            ct_rpc:call(Miner, application, load, [blockchain]),
            ct_rpc:call(Miner, application, load, [libp2p]),
            %% give each miner its own log directory
            LogRoot = PrivDir ++ "/log_" ++ atom_to_list(TestCase) ++ "_" ++ atom_to_list(Miner),
            ct_rpc:call(Miner, application, set_env, [lager, log_root, LogRoot]),
            ct_rpc:call(Miner, application, set_env, [lager, metadata_whitelist, [poc_id]]),
            %% set blockchain configuration
            Key = {PubKey, ECDH, SigFun, undefined},
            BaseDir = PrivDir ++ "/data_" ++ atom_to_list(TestCase) ++ "_" ++ atom_to_list(Miner),
            %% set blockchain env
            ct_rpc:call(Miner, application, set_env, [blockchain, base_dir, BaseDir]),
            ct_rpc:call(Miner, application, set_env, [blockchain, port, Port]),
            ct_rpc:call(Miner, application, set_env, [blockchain, seed_nodes, SeedNodes]),
            ct_rpc:call(Miner, application, set_env, [blockchain, key, Key]),
            ct_rpc:call(Miner, application, set_env, [blockchain, peer_cache_timeout, 30000]),
            ct_rpc:call(Miner, application, set_env, [blockchain, peerbook_update_interval, 200]),
            ct_rpc:call(Miner, application, set_env, [blockchain, peerbook_allow_rfc1918, true]),
            ct_rpc:call(Miner, application, set_env, [blockchain, disable_poc_v4_target_challenge_age, true]),
            ct_rpc:call(Miner, application, set_env, [blockchain, max_inbound_connections, TotalMiners*2]),
            ct_rpc:call(Miner, application, set_env, [blockchain, outbound_gossip_connections, TotalMiners]),
            %% set miner configuration
            ct_rpc:call(Miner, application, set_env, [miner, curve, Curve]),
            ct_rpc:call(Miner, application, set_env, [miner, radio_device, {{127,0,0,1}, UDPPort, {127,0,0,1}, TCPPort}]),
            ct_rpc:call(Miner, application, set_env, [miner, stabilization_period_start, 2]),

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

    %% wait until we get confirmation the miners are fully up
    %% which we are determining by the miner_consensus_mgr being registered
    %% QUESTION: is there a better process to use to determine things are healthy
    %%           and which works for both in consensus and non consensus miners?
    ok = miner_ct_utils:wait_for_registration(Miners, miner_consensus_mgr),
    %ok = miner_ct_utils:wait_for_registration(Miners, blockchain_worker),

    [
        {miners, Miners},
        {keys, Keys},
        {ports, MinersAndPorts},
        {addresses, Addresses},
        {block_time, BlockTime},
        {batch_size, BatchSize},
        {dkg_curve, Curve},
        {election_interval, Interval},
        {num_consensus_members, NumConsensusMembers},
        {rpc_timeout, timer:seconds(5)}
        | Config
    ].

end_per_testcase(TestCase, Config) ->
    Miners = proplists:get_value(miners, Config),
    miner_ct_utils:pmap(fun(Miner) -> ct_slave:stop(Miner) end, Miners),
    case proplists:get_value(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            cleanup_per_testcase(TestCase, Config);
        _ ->
            %% leave results alone for analysis
            ok
    end,
    {comment, done}.

cleanup_per_testcase(TestCase, Config) ->
    Miners = proplists:get_value(miners, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    lists:foreach(fun(Miner) ->
                          LogRoot = PrivDir ++ "/log_" ++ atom_to_list(TestCase) ++ "_" ++ atom_to_list(Miner),
                          Res = os:cmd("rm -rf " ++ LogRoot),
                          ct:pal("rm -rf ~p -> ~p", [LogRoot, Res]),
                          BaseDir = PrivDir ++ "/data_" ++ atom_to_list(TestCase) ++ "_" ++ atom_to_list(Miner),
                          Res2 = os:cmd("rm -rf " ++ BaseDir),
                          ct:pal("rm -rf ~p -> ~p", [BaseDir, Res2]),
                          ok
                  end, Miners).

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
              ?block_time => 2,
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
              ?dc_percent => 0.0,
              ?poc_challengees_percent => 0.19 + 0.16,
              ?poc_challengers_percent => 0.09 + 0.06,
              ?poc_witnesses_percent => 0.02 + 0.03,
              ?consensus_percent => 0.10,
              ?election_version => 2,
              ?election_cluster_res => 8,
              ?election_removal_pct => 85,
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
              ?poc_challenge_interval => 10,
              ?poc_version => 3,
              ?poc_path_limit => 7,
              ?poc_typo_fixes => true
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
                LegVars = maps:without([?poc_version, ?poc_path_limit,
                                        ?election_version, ?election_removal_pct, ?election_cluster_res,
                                        ?chain_vars_version, ?block_version],
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

generate_keys(N) ->
    lists:foldl(
        fun(_, Acc) ->
            {PrivKey, PubKey} = new_random_key(ecc_compact),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_bin(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
        end,
        [],
        lists:seq(1, N)
    ).

new_random_key(Curve) ->
    #{secret := PrivKey, public := PubKey} = libp2p_crypto:generate_keys(Curve),
    {PrivKey, PubKey}.


%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

handle_get_consensus_miners(Miner)->
    try
        Blockchain = ct_rpc:call(Miner, blockchain_worker, blockchain, [], 2000),
        Ledger = ct_rpc:call(Miner, blockchain, ledger, [Blockchain], 2000),
        {ok, Members} = ct_rpc:call(Miner, blockchain_ledger_v1, consensus_members, [Ledger], 2000),
        {ok, Members}
    catch
        _:_  -> {error, miner_down}

    end.

handle_miners_by_consensus(Mod, Bool, Miners)->
    lists:Mod(
            fun(Miner) ->
                Bool == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [])
            end, Miners).

handle_gte_type(height, Miner, Threshold)->
    C0 = ct_rpc:call(Miner, blockchain_worker, blockchain, [], 2000),
    {ok, Height} = ct_rpc:call(Miner, blockchain, height, [C0], 2000),
    ct:pal("miner ~p height ~p  Threshold ~p", [Miner, Height, Threshold]),
    Height >= Threshold;
handle_gte_type(epoch, Miner, Threshold)->
    {Height, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 2000),
    ct:pal("miner ~p Height ~p Epoch ~p Threshold ~p", [Miner, Height, Epoch, Threshold]),
    Epoch >= Threshold;
handle_gte_type(height_exactly, Miner, Threshold)->
    C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
    ct:pal("miner ~p height ~p Exact Threshold ~p", [Miner, Ht, Threshold]),
    Ht == Threshold.

