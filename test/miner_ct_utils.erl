-module(miner_ct_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

-export([
         init_per_testcase/3,
         end_per_testcase/2,
         pmap/2, pmap/3,
         wait_until/1, wait_until/3,
         wait_until_disconnected/2,
         start_node/1,
         partition_cluster/2,
         heal_cluster/2,
         connect/1,
         count/2,
         randname/1,
         get_config/2,
         get_balance/2,
         get_nonce/2,
         get_block/2,
         make_vars/1, make_vars/2, make_vars/3,
         tmp_dir/0, tmp_dir/1, nonl/1,
         cleanup_tmp_dir/1,
         init_base_dir_config/3,
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
         initial_dkg/5, initial_dkg/6,
         confirm_balance/3,
         confirm_balance_both_sides/5,
         wait_for_gte/3, wait_for_gte/5,

         submit_txn/2,
         wait_for_txn/2, wait_for_txn/3, wait_for_txn/4,
         format_txn_mgr_list/1,
         get_txn_block_details/2, get_txn_block_details/3,
         get_txn/2,
         get_genesis_block/2,
         load_genesis_block/3
        ]).


stop_miners(Miners) ->
    stop_miners(Miners, 60).

stop_miners(Miners, Retries) ->
    Res = [begin
               ct:pal("capturing env for ~p", [Miner]),
               LagerEnv = ct_rpc:call(Miner, application, get_all_env, [lager]),
               P2PEnv = ct_rpc:call(Miner, application, get_all_env, [libp2p]),
               BlockchainEnv = ct_rpc:call(Miner, application, get_all_env, [blockchain]),
               MinerEnv = ct_rpc:call(Miner, application, get_all_env, [miner]),
               ct:pal("stopping ~p", [Miner]),
               erlang:monitor_node(Miner, true),
               ct_slave:stop(Miner),
               receive
                   {nodedown, Miner} ->
                       ok
               after timer:seconds(Retries) ->
                       error(stop_timeout)
               end,
               ct:pal("stopped ~p", [Miner]),
               {Miner, [{lager, LagerEnv}, {libp2p, P2PEnv}, {blockchain, BlockchainEnv}, {miner, MinerEnv}]}
           end
           || Miner <- Miners],
    Res.

start_miners(Miners) ->
    start_miners(Miners, 60).

start_miners(MinersAndEnv, Retries) ->
    [begin
         ct:pal("starting ~p", [Miner]),
         start_node(Miner),
         ct:pal("loading env ~p", [Miner]),
         ok = ct_rpc:call(Miner, application, set_env, [Env]),
         ct:pal("starting miner on ~p", [Miner]),
         {ok, _StartedApps} = ct_rpc:call(Miner, application, ensure_all_started, [miner]),
         ct:pal("started miner on ~p : ~p", [Miner, _StartedApps])
     end
     || {Miner, Env} <- MinersAndEnv],
    {Miners, _Env} = lists:unzip(MinersAndEnv),
    ct:pal("waiting for blockchain worker to start on ~p", [Miners]),
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
        Result == true, 60, timer:seconds(5)),
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


submit_txn(Txn, Miners) ->
    lists:foreach(fun(Miner) ->
                          ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn])
                  end, Miners).


wait_for_gte(height = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, all, 60);
wait_for_gte(epoch = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, any, 60);
wait_for_gte(height_exactly = Type, Miners, Threshold)->
    wait_for_gte(Type, Miners, Threshold, all, 60).

wait_for_gte(Type, Miners, Threshold, Mod, Retries)->
    Res = ?noAssertAsync(begin
                     lists:Mod(
                        fun(Miner) ->
                             try
                                 handle_gte_type(Type, Miner, Threshold)
                             catch What:Why ->
                                     ct:pal("Failed to check GTE ~p ~p ~p: ~p:~p", [Type, Miner, Threshold, What, Why]),
                                     false
                             end
                        end, miner_ct_utils:shuffle(Miners))
                    end,
        Retries, timer:seconds(1)),
    case Res of
        true -> ok;
        false -> {error, false}
    end.


wait_for_registration(Miners, Mod) ->
    wait_for_registration(Miners, Mod, 300).
wait_for_registration(Miners, Mod, Timeout) ->
    ?assertAsync(begin
                     RegistrationResult
                         = lists:all(
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
        RegistrationResult, 90, timer:seconds(1)),
    ok.

wait_for_app_start(Miners, App) ->
    wait_for_app_start(Miners, App, 60).
wait_for_app_start(Miners, App, Retries) ->
    ?assertAsync(begin
                     AppStartResult =
                         lists:all(
                           fun(Miner) ->
                                   case ct_rpc:call(Miner, application, which_applications, []) of
                                       {badrpc, _} ->
                                           false;
                                       Apps ->
                                           lists:keymember(App, 1, Apps)
                                   end
                           end, Miners)
                 end,
        AppStartResult, Retries, 500),
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

                             case ct_rpc:call(Miner, blockchain, config, [num_consensus_members, L1], Timeout) of
                                 {ok, _Sz} ->
                                     true == ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, []);
                                 _ ->
                                     %% badrpc
                                     false
                             end
                         end, Miners),
                     ct:pal("size ~p", [length(Result)]),
                     Result
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
                                 R = ct_rpc:call(Miner, blockchain, config, [Key, Ledger], Timeout),
                                 ct:pal("var = ~p", [R]),
                                 {ok, Value} == R
                         end, miner_ct_utils:shuffle(Miners))
                 end,
                 Result, 40, timer:seconds(1)),
    ok.

delete_dirs(DirWildcard, SubDir)->
    Dirs = filelib:wildcard(DirWildcard),
    [begin
         ct:pal("rm dir ~s", [Dir ++ SubDir]),
         os:cmd("rm -r " ++ Dir ++ SubDir)
     end
     || Dir <- Dirs],
    ok.

initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve)->
    initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, 12000).
initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, Timeout)->
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

start_node(Name) ->
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path()),
    %% have the slave nodes monitor the runner node, so they can't outlive it
    NodeConfig = [
                  {monitor_master, true},
                  {boot_timeout, 10},
                  {init_timeout, 10},
                  {startup_timeout, 10},
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
            start_node(Name);
        {error, started_not_connected, Node} ->
            connect(Node),
            ct_slave:stop(Name),
            wait_until_offline(Node),
            start_node(Name)
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

init_per_testcase(Mod, TestCase, Config0) ->
    Config = init_base_dir_config(Mod, TestCase, Config0),
    BaseDir = ?config(base_dir, Config),
    LogDir = ?config(log_dir, Config),

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
            {miner_ct_utils:start_node(MinerName), {45000, 0}}
        end,
        lists:seq(1, TotalMiners)
    ),

    Keys = miner_ct_utils:pmap(
             fun({Miner, Ports}) ->
                     miner_ct_utils:start_node(Miner),
                     #{secret := GPriv, public := GPub} =
                     libp2p_crypto:generate_keys(ecc_compact),
                     GECDH = libp2p_crypto:mk_ecdh_fun(GPriv),
                     GAddr = libp2p_crypto:pubkey_to_bin(GPub),
                     GSigFun = libp2p_crypto:mk_sig_fun(GPriv),
                     {Miner, Ports, GECDH, GPub, GAddr, GSigFun}
             end, MinersAndPorts),

    {_Miner, {_TCPPort, _UDPPort}, _ECDH, _PubKey, Addr, _SigFun} = hd(Keys),
    DefaultRouters = libp2p_crypto:pubkey_bin_to_p2p(Addr),

    ConfigResult = miner_ct_utils:pmap(
        fun({Miner, {TCPPort, UDPPort}, ECDH, PubKey, _Addr, SigFun}) ->
                ct:pal("Miner ~p", [Miner]),
                ct_rpc:call(Miner, cover, start, []),
                ct_rpc:call(Miner, application, load, [lager]),
                ct_rpc:call(Miner, application, load, [miner]),
                ct_rpc:call(Miner, application, load, [blockchain]),
                ct_rpc:call(Miner, application, load, [libp2p]),
                %% give each miner its own log directory
                LogRoot = LogDir ++ "_" ++ atom_to_list(Miner),
                ct:pal("MinerLogRoot: ~p", [LogRoot]),
                ct_rpc:call(Miner, application, set_env, [lager, log_root, LogRoot]),
                ct_rpc:call(Miner, application, set_env, [lager, metadata_whitelist, [poc_id]]),

                %% set blockchain configuration
                Key = {PubKey, ECDH, SigFun},

                MinerBaseDir = BaseDir ++ "_" ++ atom_to_list(Miner),
                ct:pal("MinerBaseDir: ~p", [MinerBaseDir]),
                %% set blockchain env
                ct_rpc:call(Miner, application, set_env, [blockchain, base_dir, MinerBaseDir]),
                ct_rpc:call(Miner, application, set_env, [blockchain, port, Port]),
                ct_rpc:call(Miner, application, set_env, [blockchain, seed_nodes, SeedNodes]),
                ct_rpc:call(Miner, application, set_env, [blockchain, key, Key]),
                ct_rpc:call(Miner, application, set_env, [blockchain, peer_cache_timeout, 30000]),
                ct_rpc:call(Miner, application, set_env, [blockchain, peerbook_update_interval, 200]),
                ct_rpc:call(Miner, application, set_env, [blockchain, peerbook_allow_rfc1918, true]),
                ct_rpc:call(Miner, application, set_env, [blockchain, disable_poc_v4_target_challenge_age, true]),
                ct_rpc:call(Miner, application, set_env, [blockchain, max_inbound_connections, TotalMiners*2]),
                ct_rpc:call(Miner, application, set_env, [blockchain, outbound_gossip_connections, TotalMiners]),
                ct_rpc:call(Miner, application, set_env, [blockchain, sync_cooldown_time, 5]),
                %ct_rpc:call(Miner, application, set_env, [blockchain, sc_client_handler, miner_test_sc_client_handler]),
                ct_rpc:call(Miner, application, set_env, [blockchain, sc_packet_handler, miner_test_sc_packet_handler]),
                %% set miner configuration
                ct_rpc:call(Miner, application, set_env, [miner, curve, Curve]),
                ct_rpc:call(Miner, application, set_env, [miner, radio_device, {{127,0,0,1}, UDPPort, {127,0,0,1}, TCPPort}]),
                ct_rpc:call(Miner, application, set_env, [miner, stabilization_period_start, 2]),
                ct_rpc:call(Miner, application, set_env, [miner, default_routers, [DefaultRouters]]),
                ct_rpc:call(Miner, application, set_env, [miner, region_override, 'US915']),
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


    %% make sure each node is gossiping with a majority of its peers
    true = miner_ct_utils:wait_until(fun() ->
                                      lists:all(fun(Miner) ->
                                                        GossipPeers = ct_rpc:call(Miner, blockchain_swarm, gossip_peers, [], 2000),
                                                        case length(GossipPeers) >= (length(Miners) / 2) + 1 of
                                                            true -> true;
                                                            false ->
                                                                ct:pal("~p is not connected to enough peers ~p", [Miner, GossipPeers]),
                                                                Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 2000),
                                                                lists:foreach(
                                                                  fun(A) ->
                                                                          CRes = ct_rpc:call(Miner, libp2p_swarm, connect, [Swarm, A], 2000),
                                                                          ct:pal("Connecting ~p to ~p: ~p", [Miner, A, CRes])
                                                                  end, Addrs),
                                                                false
                                                        end
                                                end, Miners)
                              end),

    %% accumulate the address of each miner
    MinerTaggedAddresses = lists:foldl(
        fun(Miner, Acc) ->
            Address = ct_rpc:call(Miner, blockchain_swarm, pubkey_bin, []),
            [{Miner, Address} | Acc]
        end,
        [],
        Miners
    ),
    %% save a version of the address list with the miner and address tuple
    %% and then a version with just a list of addresses
    {_Keys, Addresses} = lists:unzip(MinerTaggedAddresses),

    {ok, _} = ct_cover:add_nodes(Miners),

    %% wait until we get confirmation the miners are fully up
    %% which we are determining by the miner_consensus_mgr being registered
    %% QUESTION: is there a better process to use to determine things are healthy
    %%           and which works for both in consensus and non consensus miners?
    ok = miner_ct_utils:wait_for_registration(Miners, miner_consensus_mgr),
    %ok = miner_ct_utils:wait_for_registration(Miners, blockchain_worker),

    UpdatedMinersAndPorts = lists:map(fun({Miner, {TCPPort, _}}) ->
                                              {ok, RandomPort} = ct_rpc:call(Miner, miner_lora, port, []),
                                              ct:pal("~p is listening for packet forwarder on ~p", [Miner, RandomPort]),
                                              {Miner, {TCPPort, RandomPort}}
                                      end, MinersAndPorts),

    [
        {miners, Miners},
        {keys, Keys},
        {ports, UpdatedMinersAndPorts},
        {addresses, Addresses},
        {tagged_miner_addresses, MinerTaggedAddresses},
        {block_time, BlockTime},
        {batch_size, BatchSize},
        {dkg_curve, Curve},
        {election_interval, Interval},
        {num_consensus_members, NumConsensusMembers},
        {rpc_timeout, timer:seconds(5)}
        | Config
    ].

end_per_testcase(TestCase, Config) ->
    Miners = ?config(miners, Config),
    miner_ct_utils:pmap(fun(Miner) -> ct_slave:stop(Miner) end, Miners),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            cleanup_per_testcase(TestCase, Config);
        _ ->
            %% leave results alone for analysis
            ok
    end,
    {comment, done}.

cleanup_per_testcase(_TestCase, Config) ->
    Miners = ?config(miners, Config),
    BaseDir = ?config(base_dir, Config),
    LogDir = ?config(log_dir, Config),
    lists:foreach(fun(Miner) ->
                          LogRoot = LogDir ++ "_" ++ atom_to_list(Miner),
                          Res = os:cmd("rm -rf " ++ LogRoot),
                          ct:pal("rm -rf ~p -> ~p", [LogRoot, Res]),
                          DataDir = BaseDir ++ "_" ++ atom_to_list(Miner),
                          Res2 = os:cmd("rm -rf " ++ DataDir),
                          ct:pal("rm -rf ~p -> ~p", [DataDir, Res2]),
                          ok
                  end, Miners).

get_balance(Miner, Addr) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, ledger, [Chain]) of
                {badrpc, Error} ->
                    Error;
                Ledger ->
                    case ct_rpc:call(Miner, blockchain_ledger_v1, find_entry, [Addr, Ledger]) of
                        {badrpc, Error} ->
                            Error;
                        {ok, Entry} ->
                            ct_rpc:call(Miner, blockchain_ledger_entry_v1, balance, [Entry])
                    end
            end
    end.

get_nonce(Miner, Addr) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, ledger, [Chain]) of
                {badrpc, Error} ->
                    Error;
                Ledger ->
                    case ct_rpc:call(Miner, blockchain_ledger_v1, find_entry, [Addr, Ledger]) of
                        {badrpc, Error} ->
                            Error;
                        {ok, Entry} ->
                            ct_rpc:call(Miner, blockchain_ledger_entry_v1, nonce, [Entry])
                    end
            end
    end.


get_block(Block, Miner) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, get_block, [Block, Chain]) of
                {badrpc, Error} ->
                    Error;
                {ok, BlockRec} ->
                    BlockRec
            end
    end.


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
              ?predicate_threshold => 0.60,
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


%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).
tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

%%--------------------------------------------------------------------
%% @doc
%% Deletes the specified directory
%% @end
%%-------------------------------------------------------------------
-spec cleanup_tmp_dir(list()) -> ok.
cleanup_tmp_dir(Dir)->
    os:cmd("rm -rf " ++ Dir),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% create a tmp directory at the specified path
%% @end
%%-------------------------------------------------------------------
-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    ?MODULE:nonl(os:cmd("mktemp -d " ++  Path)).

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory based off priv_dir to be used as a scratch by common tests
%% @end
%%-------------------------------------------------------------------
-spec init_base_dir_config(atom(), atom(), list()) -> {list(), list()}.
init_base_dir_config(Mod, TestCase, Config)->
    PrivDir = ?config(priv_dir, Config),
    BaseDir = PrivDir ++ "data/" ++ erlang:atom_to_list(Mod) ++ "_" ++ erlang:atom_to_list(TestCase),
    LogDir = PrivDir ++ "logs/" ++ erlang:atom_to_list(Mod) ++ "_" ++ erlang:atom_to_list(TestCase),
    [
        {base_dir, BaseDir},
        {log_dir, LogDir}
        | Config
    ].

%%--------------------------------------------------------------------
%% @doc
%% Wait for a txn to occur.
%%
%% Examples:
%%
%% CheckType = fun(T) -> blockchain_txn:type(T) == SomeTxnType end,
%% wait_for_txn(Miners, CheckType)
%%
%% CheckTxn = fun(T) -> T == SomeSignedTxn end,
%% wait_for_txn(Miners, CheckTxn)
%%
%% @end
%%-------------------------------------------------------------------
wait_for_txn(Miners, PredFun) ->
    wait_for_txn(Miners, PredFun, timer:seconds(30), true).

wait_for_txn(Miners, PredFun, Timeout) ->
    wait_for_txn(Miners, PredFun, Timeout, true).

wait_for_txn(Miners, PredFun, Timeout, ExpectedResult)->
    ?assertAsync(begin
                     Result = lists:all(
                                fun(Miner) ->
                                        Res = get_txn_block_details(Miner, PredFun, Timeout),
                                        Res /= []

                                end, miner_ct_utils:shuffle(Miners))
                 end,
                 Result == ExpectedResult, 40, timer:seconds(1)),
    ok.

format_txn_mgr_list(TxnList) ->
    maps:fold(fun(Txn, TxnData, Acc) ->
                    TxnMod = blockchain_txn:type(Txn),
                    TxnHash = blockchain_txn:hash(Txn),
                    Acceptions = proplists:get_value(acceptions, TxnData, []),
                    Rejections = proplists:get_value(rejections, TxnData, []),
                    RecvBlockHeight = proplists:get_value(recv_block_height, TxnData, undefined),
                    Dialers = proplists:get_value(dialers, TxnData, undefined),
                      [
                       [{txn_type, atom_to_list(TxnMod)},
                       {txn_hash, io_lib:format("~p", [libp2p_crypto:bin_to_b58(TxnHash)])},
                       {acceptions, length(Acceptions)},
                       {rejections, length(Rejections)},
                       {accepted_block_height, RecvBlockHeight},
                       {active_dialers, length(Dialers)}]
                      | Acc]
              end, [], TxnList).

get_txn_block_details(Miner, PredFun) ->
    get_txn_block_details(Miner, PredFun, timer:seconds(5)).

get_txn_block_details(Miner, PredFun, Timeout) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, [], Timeout) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, blocks, [Chain], Timeout) of
                {badrpc, Error} ->
                    Error;
                Blocks ->
                    lists:filter(fun({_Hash, Block}) ->
                                               %% BH = blockchain_block:height(Block),
                                               Txns = blockchain_block:transactions(Block),
                                               ToFind = lists:filter(fun(T) ->
                                                                             PredFun(T)
                                                                     end,
                                                                     Txns),
                                               %% ct:pal("BlockHeight: ~p, ToFind: ~p", [BH, ToFind]),
                                               ToFind /= []
                                       end,
                                       maps:to_list(Blocks))
            end
    end.

get_txn([{_, B}], PredFun) ->
    hd(lists:filter(fun(T) ->
                            PredFun(T)
                    end,
                    blockchain_block:transactions(B))).

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
    case Height >= Threshold of
        false ->
            ct:pal("miner ~p height ~p  Threshold ~p", [Miner, Height, Threshold]),
            false;
        true ->
            true
    end;
handle_gte_type(epoch, Miner, Threshold)->
    {Height, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 2000),
    ct:pal("miner ~p Height ~p Epoch ~p Threshold ~p", [Miner, Height, Epoch, Threshold]),
    Epoch >= Threshold;
handle_gte_type(height_exactly, Miner, Threshold)->
    C = ct_rpc:call(Miner, blockchain_worker, blockchain, []),
    {ok, Ht} = ct_rpc:call(Miner, blockchain, height, [C]),
    ct:pal("miner ~p height ~p Exact Threshold ~p", [Miner, Ht, Threshold]),
    Ht == Threshold.

get_genesis_block(Miners, Config) ->
    RPCTimeout = ?config(rpc_timeout, Config),
    ct:pal("RPCTimeout: ~p", [RPCTimeout]),
    %% obtain the genesis block
    GenesisBlock = get_genesis_block_(Miners, RPCTimeout),
    ?assertNotEqual(undefined, GenesisBlock),
    GenesisBlock.

get_genesis_block_([Miner|Miners], RPCTimeout) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, [], RPCTimeout) of
        {badrpc, Reason} ->
            ct:fail(Reason),
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        undefined ->
            get_genesis_block_(Miners ++ [Miner], RPCTimeout);
        Chain ->
            {ok, GBlock} = rpc:call(Miner, blockchain, genesis_block, [Chain], RPCTimeout),
            GBlock
    end.

load_genesis_block(GenesisBlock, Miners, Config) ->
    RPCTimeout = ?config(rpc_timeout, Config),
    %% load the genesis block on all the nodes
    lists:foreach(
        fun(Miner) ->
                %% wait for the consensus manager to be booted
                true = miner_ct_utils:wait_until(
                  fun() ->
                          is_boolean(ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], RPCTimeout))
                  end),
                case ct_rpc:call(Miner, miner_consensus_mgr, in_consensus, [], RPCTimeout) of
                    true ->
                        ok;
                    false ->
                        Res = ct_rpc:call(Miner, blockchain_worker,
                                          integrate_genesis_block, [GenesisBlock], RPCTimeout),
                        ct:pal("loading genesis ~p block on ~p ~p", [GenesisBlock, Miner, Res]);
                    {badrpc, Reason} ->
                        ct:pal("failed to load genesis block on ~p: ~p", [Miner, Reason])
                end
        end,
        Miners
    ),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 1, all, 30).
