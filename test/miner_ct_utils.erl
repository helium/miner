-module(miner_ct_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-include("miner_ct_macros.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

-export([
         init_per_testcase/3,
         end_per_testcase/2,
         pmap/2, pmap/3,
         wait_until/1, wait_until/3,
         wait_until_disconnected/2,
         get_addrs/1,
         start_miner/2,
         start_node/1,
         partition_cluster/2,
         heal_cluster/2,
         connect/1,
         count/2,
         randname/1,
         get_config/2,
         get_gw_owner/2,
         get_balance/2,
         get_nonce/2,
         get_dc_balance/2,
         get_dc_nonce/2,
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
         unique_heights/1,
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
         wait_for_equalized_heights/1,
         wait_for_chain_stall/1,
         wait_for_chain_stall/2,
         assert_chain_halted/1,
         assert_chain_halted/3,
         assert_chain_advanced/1,
         assert_chain_advanced/3,

         submit_txn/2,
         wait_for_txn/2, wait_for_txn/3, wait_for_txn/4,
         format_txn_mgr_list/1,
         get_txn_block_details/2, get_txn_block_details/3,
         get_txn/2, get_txns/2,
         get_genesis_block/2,
         load_genesis_block/3,
         chain_var_lookup_all/2,
         chain_var_lookup_one/2,
         build_gateways/2,
         build_asserts/2,
         add_block/3,
         gen_gateways/2, gen_payments/1, gen_locations/1,
         existing_vars/0, start_blockchain/2
        ]).

chain_var_lookup_all(Key, Nodes) ->
    [chain_var_lookup_one(Key, Node) || Node <- Nodes].

chain_var_lookup_one(Key, Node) ->
    Chain = ct_rpc:call(Node, blockchain_worker, blockchain, [], 500),
    Ledger = ct_rpc:call(Node, blockchain, ledger, [Chain]),
    Result = ct_rpc:call(Node, blockchain, config, [Key, Ledger], 500),
    ct:pal("Var lookup. Node:~p, Result:~p", [Node, Result]),
    Result.

-spec assert_chain_advanced([node()]) -> ok.
assert_chain_advanced(Miners) ->
    Height = wait_for_equalized_heights(Miners),
    ?assertMatch(
        ok,
        miner_ct_utils:wait_for_gte(height, Miners, Height + 1),
        "Chain advanced."
    ),
    ok.

assert_chain_advanced(_, _, N) when N =< 0 ->
    ok;
assert_chain_advanced(Miners, Interval, N) ->
    ok = assert_chain_advanced(Miners),
    timer:sleep(Interval),
    assert_chain_advanced(Miners, Interval, N - 1).

-spec assert_chain_halted([node()]) -> ok.
assert_chain_halted(Miners) ->
    assert_chain_halted(Miners, 5000, 20).

-spec assert_chain_halted([node()], timeout(), pos_integer()) -> ok.
assert_chain_halted(Miners, Interval, Retries) ->
    _ = lists:foldl(
        fun (_, HeightPrev) ->
            HeightCurr = wait_for_equalized_heights(Miners),
            ?assertEqual(HeightPrev, HeightCurr, "Chain halted."),
            timer:sleep(Interval),
            HeightCurr
        end,
        wait_for_equalized_heights(Miners),
        lists:duplicate(Retries, {})
    ),
    ok.

wait_for_chain_stall(Miners) ->
    wait_for_chain_stall(Miners, #{}).

-spec wait_for_chain_stall([node()], Options) -> ok | error when
    Options :: #{
        interval      => timeout(),
        retries_max   => pos_integer(),
        streak_target => pos_integer()
    }.
wait_for_chain_stall(Miners, Options=#{}) ->
    State =
        #{
            interval      => maps:get(interval, Options, 5000),
            retries_max   => maps:get(retries_max, Options, 100),
            streak_target => maps:get(streak_target, Options, 5),
            streak_prev   => 0,
            retries_cur   => 0,
            height_prev   => 0
         },
    wait_for_chain_stall_(Miners, State).

wait_for_chain_stall_(_, #{streak_target := Target, streak_prev := Streak}) when Streak >= Target ->
    ok;
wait_for_chain_stall_(_, #{retries_cur := Cur, retries_max := Max}) when Cur >= Max ->
    error;
wait_for_chain_stall_(
    Miners,
    #{
        interval    := Interval,
        streak_prev := StreakPrev,
        height_prev := HeightPrev,
        retries_cur := RetriesCur
    }=State0
) ->
    {HeightCurr, StreakCurr} =
        case wait_for_equalized_heights(Miners) of
            HeightPrev -> {HeightPrev, 1 + StreakPrev};
            HeightCurr0 -> {HeightCurr0, 0}
        end,
    timer:sleep(Interval),
    State1 = State0#{
        height_prev := HeightCurr,
        streak_prev := StreakCurr,
        retries_cur := RetriesCur + 1
    },
    wait_for_chain_stall_(Miners, State1).

-spec wait_for_equalized_heights([node()]) -> non_neg_integer().
wait_for_equalized_heights(Miners) ->
    ?assert(
        miner_ct_utils:wait_until(
            fun() ->
                case unique_heights(Miners) of
                    [_] -> true;
                    [_|_] -> false
                end
            end,
            50,
            1000
        ),
        "Heights equalized."
    ),
    UniqueHeights = unique_heights(Miners),
    ?assertMatch([_], UniqueHeights, "All heights are equal."),
    [Height] = UniqueHeights,
    Height.

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

start_miner(Name0, Options) ->
    Name = start_node(Name0),
    Keys = make_keys(Name, {45000, 0, 4466}),
    config_node(Keys, Options),
    {Name, Keys}.

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

-spec unique_heights([node()]) -> [non_neg_integer()].
unique_heights(Miners) ->
    lists:usort([H || {_, H} <- miner_ct_utils:heights(Miners)]).

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
    NotSeen =
        try
            Members = miner_ct_utils:consensus_members(Miners),
            MinerNames = lists:map(fun(Member)-> miner_ct_utils:addr2node(Member, AddrList) end, Members),
            NotSeen1 = NotSeen0 -- MinerNames,
            Owner ! {not_seen, NotSeen1},
            NotSeen1
        catch _C:_E ->
                NotSeen0
        end,
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
                                             ct:pal("~p result ~p~n", [Miner, Other]),
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
    wait_for_app_stop(Miners, App, 30).
wait_for_app_stop(Miners, App, Retries) ->
    ?assertAsync(begin
                     Result = lists:all(
                         fun(Miner) ->
                             case ct_rpc:call(Miner, application, which_applications, []) of
                                 {badrpc, nodedown} ->
                                     true;
                                 {badrpc, _Which} ->
                                     ct:pal("~p ~p", [Miner, _Which]),
                                     false;
                                 Apps ->
                                     ct:pal("~p ~p", [Miner, Apps]),
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
    wait_for_chain_var_update(Miners, Key, Value, 20).

wait_for_chain_var_update(Miners, Key, Value, Retries)->
    case wait_until(
           fun() ->
                   lists:all(
                     fun(Miner) ->
                             {ok, Value} == chain_var_lookup_one(Key, Miner)
                     end, miner_ct_utils:shuffle(Miners))
           end,
           Retries * 2, 500) of
        %% back compat
        true -> ok;
        Else -> Else
    end.

delete_dirs(DirWildcard, SubDir)->
    Dirs = filelib:wildcard(DirWildcard),
    [begin
         ct:pal("rm dir ~s", [Dir ++ SubDir]),
         os:cmd("rm -r " ++ Dir ++ SubDir)
     end
     || Dir <- Dirs],
    ok.

initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve)->
    initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, 60000).
initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve, Timeout) ->
    SuperParent = self(),
    SuperTimeout = Timeout + 5000,
    Threshold = (NumConsensusMembers - 1) div 3,
    spawn(fun() ->
                  Parent = self(),

                  lists:foreach(
                    fun(Miner) ->
                            spawn(fun() ->
                                          Res = ct_rpc:call(Miner, miner_consensus_mgr, initial_dkg,
                                                            [Txns, Addresses, NumConsensusMembers, Curve], Timeout),
                                          Parent ! {Miner, Res}
                                  end)
                    end, Miners),
                  SuperParent ! receive_dkg_results(Threshold, Miners, [])
          end),
    receive
        DKGResults ->
            DKGResults
    after SuperTimeout ->
              {error, dkg_timeout}
    end.

receive_dkg_results(Threshold, [], OKResults) ->
    ct:pal("only ~p completed dkg, lower than threshold of ~p", [OKResults, Threshold]),
    {error, insufficent_dkg_completion};
receive_dkg_results(Threshold, _Miners, OKResults) when length(OKResults) >= Threshold ->
    {ok, OKResults};
receive_dkg_results(Threshold, Miners, OKResults) ->
    receive
        {Miner, ok} ->
            case lists:member(Miner, Miners) of
                true ->
                    receive_dkg_results(Threshold, Miners -- [Miner], [Miner|OKResults]);
                false ->
                    receive_dkg_results(Threshold, Miners, OKResults)
            end;
        {Miner, OtherResult} ->
            ct:pal("Miner ~p failed DKG: ~p", [Miner, OtherResult]),
            receive_dkg_results(Threshold, Miners -- [Miner], OKResults)
    end.



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
    L2 = [receive
              {pmap, N, R} ->
                  {N,R}
          after Timeout->
                    error(timeout_expired)
          end || _ <- L],
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
            start_node(Name);
        Other ->
            Other
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
            validator_transition_test ->
                4;
            autoskip_chain_vars_test ->
                4;
            autoskip_on_timeout_test ->
                4;
            _ ->
                get_config("N", 7)
        end,
    SeedNodes = [],
    JsonRpcBase = 4486,
    Port = get_config("PORT", 0),
    Curve = 'SS512',
    BlockTime = get_config("BT", 100),
    BatchSize = get_config("BS", 500),
    Interval = get_config("INT", 5),

    MinersAndPorts = miner_ct_utils:pmap(
        fun(I) ->
            MinerName = list_to_atom(integer_to_list(I) ++ miner_ct_utils:randname(5)),
            {start_node(MinerName), {45000, 0, JsonRpcBase + I}}
        end,
        lists:seq(1, TotalMiners)
    ),

    case lists:any(fun({{error, _}, _}) -> true; (_) -> false end, MinersAndPorts) of
        true ->
            %% kill any nodes we started and throw error
            miner_ct_utils:pmap(fun({error, _}) -> ok; (Miner) -> ct_slave:stop(Miner) end, element(1, lists:unzip(MinersAndPorts))),
            throw(hd([ E || {{error, E}, _} <- MinersAndPorts ]));
        false ->
            ok
    end,

    Keys = miner_ct_utils:pmap(
             fun({Miner, Ports}) ->
                     make_keys(Miner, Ports)
             end, MinersAndPorts),

    {_Miner, {_TCPPort, _UDPPort, _JsonRpcPort}, _ECDH, _PubKey, Addr, _SigFun} = hd(Keys),
    DefaultRouters = libp2p_crypto:pubkey_bin_to_p2p(Addr),

    Options = [{mod, Mod},
               {logdir, LogDir},
               {basedir, BaseDir},
               {seed_nodes, SeedNodes},
               {total_miners, TotalMiners},
               {curve, Curve},
               {default_routers, DefaultRouters},
               {port, Port}],

    ConfigResult = miner_ct_utils:pmap(fun(N) -> config_node(N, Options) end, Keys),

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

    Addrs = get_addrs(Miners),

    miner_ct_utils:pmap(
      fun(Miner) ->
              Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 2000),
              lists:foreach(
                fun(A) ->
                        ct_rpc:call(Miner, libp2p_swarm, connect, [Swarm, A], 2000)
                end, Addrs)
      end, Miners),

    %% make sure each node is gossiping with a majority of its peers
    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               try
                                   GossipPeers = ct_rpc:call(Miner, blockchain_swarm, gossip_peers, [], 500),
                                   ct:pal("Miner: ~p, GossipPeers: ~p", [Miner, GossipPeers]),
                                   case length(GossipPeers) >= (length(Miners) / 2) + 1 of
                                       true -> true;
                                       false ->
                                           ct:pal("~p is not connected to enough peers ~p", [Miner, GossipPeers]),
                                           Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 500),
                                           lists:foreach(
                                             fun(A) ->
                                                     CRes = ct_rpc:call(Miner, libp2p_swarm, connect, [Swarm, A], 500),
                                                     ct:pal("Connecting ~p to ~p: ~p", [Miner, A, CRes])
                                             end, Addrs),
                                           false
                                   end
                               catch _C:_E ->
                                       false
                               end
                       end, Miners)
             end, 200, 150),

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

    UpdatedMinersAndPorts = lists:map(fun({Miner, {TCPPort, _, JsonRpcPort}}) ->
                                              {ok, RandomPort} = ct_rpc:call(Miner, miner_lora, port, []),
                                              ct:pal("~p is listening for packet forwarder on ~p", [Miner, RandomPort]),
                                              {Miner, {TCPPort, RandomPort, JsonRpcPort}}
                                      end, MinersAndPorts),

    [
        {miners, Miners},
        {keys, Keys},
        {ports, UpdatedMinersAndPorts},
        {node_options, Options},
        {addresses, Addresses},
        {tagged_miner_addresses, MinerTaggedAddresses},
        {block_time, BlockTime},
        {batch_size, BatchSize},
        {dkg_curve, Curve},
        {election_interval, Interval},
        {num_consensus_members, NumConsensusMembers},
        {rpc_timeout, timer:seconds(30)}
        | Config
    ].

get_addrs(Miners) ->
    miner_ct_utils:pmap(
      fun(Miner) ->
              Swarm = ct_rpc:call(Miner, blockchain_swarm, swarm, [], 2000),
              true = miner_ct_utils:wait_until(
                       fun() ->
                               length(ct_rpc:call(Miner, libp2p_swarm, listen_addrs, [Swarm], 2000)) > 0
                       end),
              ct:pal("swarm ~p ~p", [Miner, Swarm]),
              [H|_] = ct_rpc:call(Miner, libp2p_swarm, listen_addrs, [Swarm], 2000),
              H
      end, Miners).

make_keys(Miner, Ports) ->
    #{secret := GPriv, public := GPub} =
        libp2p_crypto:generate_keys(ecc_compact),
    GECDH = libp2p_crypto:mk_ecdh_fun(GPriv),
    GAddr = libp2p_crypto:pubkey_to_bin(GPub),
    GSigFun = libp2p_crypto:mk_sig_fun(GPriv),
    {Miner, Ports, GECDH, GPub, GAddr, GSigFun}.

config_node({Miner, {TCPPort, UDPPort, JSONRPCPort}, ECDH, PubKey, _Addr, SigFun}, Options) ->
    Mod = proplists:get_value(mod, Options),
    LogDir = proplists:get_value(logdir, Options),
    BaseDir = proplists:get_value(basedir, Options),
    SeedNodes = proplists:get_value(seed_nodes, Options),
    TotalMiners = proplists:get_value(total_miners, Options),
    Curve = proplists:get_value(curve, Options),
    DefaultRouters = proplists:get_value(default_routers, Options),
    Port = proplists:get_value(port, Options),

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
    ct_rpc:call(Miner, application, set_env, [blockchain, enable_nat, false]),
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
    %% ct_rpc:call(Miner, application, set_env, [blockchain, sc_client_handler, miner_test_sc_client_handler]),
    ct_rpc:call(Miner, application, set_env, [blockchain, sc_packet_handler, miner_test_sc_packet_handler]),
    %% set miner configuration
    ct_rpc:call(Miner, application, set_env, [miner, curve, Curve]),
    ct_rpc:call(Miner, application, set_env, [miner, jsonrpc_port, JSONRPCPort]),
    ct_rpc:call(Miner, application, set_env, [miner, mode, validator]),
    ct_rpc:call(Miner, application, set_env, [miner, radio_device, {{127,0,0,1}, UDPPort, {127,0,0,1}, TCPPort}]),
    ct_rpc:call(Miner, application, set_env, [miner, stabilization_period_start, 2]),
    ct_rpc:call(Miner, application, set_env, [miner, default_routers, [DefaultRouters]]),
    case Mod of
        miner_poc_v11_SUITE ->
            %% Don't set anything region related with poc-v11
            ok;
        _ ->
            ct_rpc:call(Miner, application, set_env, [miner, region_override, 'US915']),
            ct_rpc:call(Miner, application, set_env,
                        [miner, frequency_data,
                         #{'US915' => [903.9, 904.1, 904.3, 904.5, 904.7, 904.9, 905.1, 905.3],
                           'EU868' => [867.1, 867.3, 867.5, 867.7, 867.9, 868.1, 868.3, 868.5],
                           'EU433' => [433.175, 433.375, 433.575],
                           'CN470' => [486.3, 486.5, 486.7, 486.9, 487.1, 487.3, 487.5, 487.7 ],
                           'CN779' => [779.5, 779.7, 779.9],
                           'AU915' => [916.8, 917.0, 917.2, 917.4, 917.5, 917.6, 917.8, 918.0, 918.2],
                           'AS923' => [923.2, 923.4, 923.6, 923.8, 924.0, 924.2, 924.4, 924.5, 924.6, 924.8],
                           'KR920' => [922.1, 922.3, 922.5, 922.7, 922.9, 923.1, 923.3],
                           'IN865' => [865.0625, 865.4025, 865.985]}])
    end,
    {ok, _StartedApps} = ct_rpc:call(Miner, application, ensure_all_started, [miner]),
    ok.

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

get_gw_owner(Miner, GwAddr) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, ledger, [Chain]) of
                {badrpc, Error} ->
                    Error;
                Ledger ->
                    case ct_rpc:call(Miner, blockchain_ledger_v1, find_gateway_info,
                                     [GwAddr, Ledger]) of
                        {badrpc, Error} ->
                            Error;
                        {ok, GwInfo} ->
                            ct_rpc:call(Miner, blockchain_ledger_gateway_v2, owner_address,
                                        [GwInfo])
                    end
            end
    end.


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

get_dc_balance(Miner, Addr) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, ledger, [Chain]) of
                {badrpc, Error} ->
                    Error;
                Ledger ->
                    case ct_rpc:call(Miner, blockchain_ledger_v1, find_dc_entry, [Addr, Ledger]) of
                        {badrpc, Error} ->
                            Error;
                        {ok, Entry} ->
                            ct_rpc:call(Miner, blockchain_ledger_data_credits_entry_v1, balance, [Entry])
                    end
            end
    end.

get_dc_nonce(Miner, Addr) ->
    case ct_rpc:call(Miner, blockchain_worker, blockchain, []) of
        {badrpc, Error} ->
            Error;
        Chain ->
            case ct_rpc:call(Miner, blockchain, ledger, [Chain]) of
                {badrpc, Error} ->
                    Error;
                Ledger ->
                    case ct_rpc:call(Miner, blockchain_ledger_v1, find_dc_entry, [Addr, Ledger]) of
                        {badrpc, Error} ->
                            Error;
                        {ok, Entry} ->
                            ct_rpc:call(Miner, blockchain_ledger_data_credits_entry_v1, nonce, [Entry])
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
              ?vars_commit_delay => 1,
              ?var_gw_inactivity_threshold => 20,
              ?block_version => v1,
              ?dkg_curve => 'SS512',
              ?predicate_callback_mod => miner,
              ?predicate_callback_fun => test_version,
              ?predicate_threshold => 0.60,
              ?monthly_reward => 5000000 * 1000000,
              ?securities_percent => 0.35,
              ?dc_percent => 0.0,
              ?poc_challengees_percent => 0.19 + 0.16,
              ?poc_challengers_percent => 0.09 + 0.06,
              ?poc_witnesses_percent => 0.02 + 0.03,
              ?consensus_percent => 0.10,
              ?election_version => 5,
              ?election_bba_penalty => 0.01,
              ?election_seen_penalty => 0.05,
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
              ?poc_typo_fixes => true,
              ?sc_grace_blocks => 4,
              ?validator_version => 2,
              ?validator_minimum_stake => ?bones(10000),
              ?validator_liveness_grace_period => 10,
              ?validator_liveness_interval => 5,
              ?stake_withdrawal_cooldown => 55,
              ?dkg_penalty => 1.0,
              ?tenure_penalty => 1.0,
              ?validator_penalty_filter => 5.0,
              ?penalty_history_limit => 100
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
                LegVars = maps:without([?poc_version, ?poc_path_limit, ?sc_grace_blocks,
                                        ?election_version, ?election_removal_pct, ?election_cluster_res,
                                        ?chain_vars_version, ?block_version, ?election_bba_penalty,
                                        ?election_seen_penalty, ?sc_grace_blocks, ?validator_minimum_stake,
                                        ?validator_liveness_grace_period, ?validator_liveness_interval,
                                        ?poc_typo_fixes, ?election_bba_penalty, ?election_seen_penalty,
                                        ?election_cluster_res, ?stake_withdrawal_cooldown,
                                        ?validator_penalty_filter
                                       ],
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
-spec init_base_dir_config(atom(), atom(), Config) -> Config when
    Config :: ct_suite:ct_config().
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
    %% timeout is in ms, we want to retry every 200
    Count = Timeout div 200,
    ?assertAsync(begin
                     Result = lists:all(
                                fun(Miner) ->
                                        Res = get_txn_block_details(Miner, PredFun, 500),
                                        Res /= []

                                end, miner_ct_utils:shuffle(Miners))
                 end,
                 Result == ExpectedResult, Count, 200),
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

get_txns(Blocks, PredFun) when is_map(Blocks) ->
    lists:foldl(fun({_, B}, Acc) ->
                        Acc ++ lists:filter(fun(T) -> PredFun(T) end,
                                            blockchain_block:transactions(B))
                end, [], maps:to_list(Blocks)).


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

build_gateways(LatLongs, {PrivKey, PubKey}) ->
    lists:foldl(
        fun({_LatLong, {GatewayPrivKey, GatewayPubKey}}, Acc) ->
            % Create a Gateway
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_bin(PubKey),

            AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway),
            SignedOwnerAddGatewayTx = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
            SignedGatewayAddGatewayTx = blockchain_txn_add_gateway_v1:sign_request(SignedOwnerAddGatewayTx, GatewaySigFun),
            [SignedGatewayAddGatewayTx|Acc]

        end,
        [],
        LatLongs
    ).

build_asserts(LatLongs, {PrivKey, PubKey}) ->
    lists:foldl(
        fun({LatLong, {GatewayPrivKey, GatewayPubKey}}, Acc) ->
            Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
            GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
            OwnerSigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            Owner = libp2p_crypto:pubkey_to_bin(PubKey),
            Index = h3:from_geo(LatLong, 12),
            AssertLocationRequestTx = blockchain_txn_assert_location_v1:new(Gateway, Owner, Index, 1),
            PartialAssertLocationTxn = blockchain_txn_assert_location_v1:sign_request(AssertLocationRequestTx, GatewaySigFun),
            SignedAssertLocationTx = blockchain_txn_assert_location_v1:sign(PartialAssertLocationTxn, OwnerSigFun),
            [SignedAssertLocationTx|Acc]
        end,
        [],
        LatLongs
    ).

add_block(Chain, ConsensusMembers, Txns) ->
    SortedTxns = lists:sort(fun blockchain_txn:sort/2, Txns),
    B = create_block(ConsensusMembers, SortedTxns),
    ok = blockchain:add_block(B, Chain).

create_block(ConsensusMembers, Txs) ->
    Blockchain = blockchain_worker:blockchain(),
    {ok, PrevHash} = blockchain:head_hash(Blockchain),
    {ok, HeadBlock} = blockchain:head_block(Blockchain),
    Height = blockchain_block:height(HeadBlock) + 1,
    Block0 = blockchain_block_v1:new(#{prev_hash => PrevHash,
                                       height => Height,
                                       transactions => Txs,
                                       signatures => [],
                                       time => 0,
                                       hbbft_round => 0,
                                       election_epoch => 1,
                                       epoch_start => 1,
                                       seen_votes => [],
                                       bba_completion => <<>>}),
    BinBlock = blockchain_block:serialize(blockchain_block:set_signatures(Block0, [])),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:set_signatures(Block0, Signatures),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun({A, {_, _, F}}, Acc) ->
            Sig = F(BinBlock),
            [{A, Sig}|Acc]
        end
        ,[]
        ,ConsensusMembers
    ).

gen_gateways(Addresses, Locations) ->
    [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
     || {Addr, Loc} <- lists:zip(Addresses, Locations)].

gen_payments(Addresses) ->
    [ blockchain_txn_coinbase_v1:new(Addr, 5000)
      || Addr <- Addresses].

%% ideally keep these synced with mainnet
existing_vars() ->
    #{
        ?allow_payment_v2_memos => true,
        ?allow_zero_amount => false,
        ?alpha_decay => 0.0035,
        ?assert_loc_txn_version => 2,
        ?batch_size => 400,
        ?beta_decay => 0.002,
        ?block_time => 60000,
        ?block_version => v1,
        ?chain_vars_version => 2,
        ?consensus_percent => 0.06,
        ?data_aggregation_version => 2,
        ?dc_payload_size => 24,
        ?dc_percent => 0.325,
        ?density_tgt_res => 4,
        ?dkg_curve => 'SS512',
        ?election_bba_penalty => 0.001,
        ?election_cluster_res => 4,
        ?election_interval => 30,
        ?election_removal_pct => 40,
        ?election_replacement_factor => 4,
        ?election_replacement_slope => 20,
        ?election_restart_interval => 5,
        ?election_seen_penalty => 0.0033333,
        ?election_selection_pct => 1,
        ?election_version => 4,
        ?h3_exclusion_ring_dist => 6,
        ?h3_max_grid_distance => 120,
        ?h3_neighbor_res => 12,
        ?hip17_interactivity_blocks => 3600,
        ?hip17_res_0 => <<"2,100000,100000">>,
        ?hip17_res_1 => <<"2,100000,100000">>,
        ?hip17_res_10 => <<"2,1,1">>,
        ?hip17_res_11 => <<"2,100000,100000">>,
        ?hip17_res_12 => <<"2,100000,100000">>,
        ?hip17_res_2 => <<"2,100000,100000">>,
        ?hip17_res_3 => <<"2,100000,100000">>,
        ?hip17_res_4 => <<"1,250,800">>,
        ?hip17_res_5 => <<"1,100,400">>,
        ?hip17_res_6 => <<"1,25,100">>,
        ?hip17_res_7 => <<"2,5,20">>,
        ?hip17_res_8 => <<"2,1,4">>,
        ?hip17_res_9 => <<"2,1,2">>,
        ?max_antenna_gain => 150,
        ?max_open_sc => 5,
        ?max_payments => 50,
        ?max_staleness => 100000,
        ?max_subnet_num => 5,
        ?max_subnet_size => 65536,
        ?max_xor_filter_num => 5,
        ?max_xor_filter_size => 102400,
        ?min_antenna_gain => 10,
        ?min_assert_h3_res => 12,
        ?min_expire_within => 15,
        ?min_score => 0.15,
        ?min_subnet_size => 8,
        ?monthly_reward => 500000000000000,
        ?num_consensus_members => 16,
        ?poc_addr_hash_byte_count => 8,
        ?poc_centrality_wt => 0.5,
        ?poc_challenge_interval => 480,
        ?poc_challenge_sync_interval => 90,
        ?poc_challengees_percent => 0.0531,
        ?poc_challengers_percent => 0.0095,
        ?poc_good_bucket_high => -70,
        ?poc_good_bucket_low => -130,
        ?poc_max_hop_cells => 2000,
        ?poc_path_limit => 1,
        ?poc_per_hop_max_witnesses => 25,
        ?poc_reward_decay_rate => 0.8,
        ?poc_target_hex_parent_res => 5,
        ?poc_typo_fixes => true,
        ?poc_v4_exclusion_cells => 8,
        ?poc_v4_parent_res => 11,
        ?poc_v4_prob_bad_rssi => 0.01,
        ?poc_v4_prob_count_wt => 0.0,
        ?poc_v4_prob_good_rssi => 1.0,
        ?poc_v4_prob_no_rssi => 0.5,
        ?poc_v4_prob_rssi_wt => 0.0,
        ?poc_v4_prob_time_wt => 0.0,
        ?poc_v4_randomness_wt => 0.5,
        ?poc_v4_target_challenge_age => 1000,
        ?poc_v4_target_exclusion_cells => 6000,
        ?poc_v4_target_prob_edge_wt => 0.0,
        ?poc_v4_target_prob_score_wt => 0.0,
        ?poc_v4_target_score_curve => 5,
        ?poc_v5_target_prob_randomness_wt => 1.0,
        ?poc_version => 10,
        ?poc_witness_consideration_limit => 20,
        ?poc_witnesses_percent => 0.2124,
        ?predicate_callback_fun => version,
        ?predicate_callback_mod => miner,
        ?predicate_threshold => 0.95,
        ?price_oracle_height_delta => 10,
        ?price_oracle_price_scan_delay => 3600,
        ?price_oracle_price_scan_max => 90000,
        ?price_oracle_public_keys =>
            <<33, 1, 32, 30, 226, 70, 15, 7, 0, 161, 150, 108, 195, 90, 205, 113, 146, 41, 110, 194,
                43, 86, 168, 161, 93, 241, 68, 41, 125, 160, 229, 130, 205, 140, 33, 1, 32, 237, 78,
                201, 132, 45, 19, 192, 62, 81, 209, 208, 156, 103, 224, 137, 51, 193, 160, 15, 96,
                238, 160, 42, 235, 174, 99, 128, 199, 20, 154, 222, 33, 1, 143, 166, 65, 105, 75,
                56, 206, 157, 86, 46, 225, 174, 232, 27, 183, 145, 248, 50, 141, 210, 144, 155, 254,
                80, 225, 240, 164, 164, 213, 12, 146, 100, 33, 1, 20, 131, 51, 235, 13, 175, 124,
                98, 154, 135, 90, 196, 83, 14, 118, 223, 189, 221, 154, 181, 62, 105, 183, 135, 121,
                105, 101, 51, 163, 119, 206, 132, 33, 1, 254, 129, 70, 123, 51, 101, 208, 224, 99,
                172, 62, 126, 252, 59, 130, 84, 93, 231, 214, 248, 207, 139, 84, 158, 120, 232, 6,
                8, 121, 243, 25, 205, 33, 1, 148, 214, 252, 181, 1, 33, 200, 69, 148, 146, 34, 29,
                22, 91, 108, 16, 18, 33, 45, 0, 210, 100, 253, 211, 177, 78, 82, 113, 122, 149, 47,
                240, 33, 1, 170, 219, 208, 73, 156, 141, 219, 148, 7, 148, 253, 209, 66, 48, 218,
                91, 71, 232, 244, 198, 253, 236, 40, 201, 90, 112, 61, 236, 156, 69, 235, 109, 33,
                1, 154, 235, 195, 88, 165, 97, 21, 203, 1, 161, 96, 71, 236, 193, 188, 50, 185, 214,
                15, 14, 86, 61, 245, 131, 110, 22, 150, 8, 48, 174, 104, 66, 33, 1, 254, 248, 78,
                138, 218, 174, 201, 86, 100, 210, 209, 229, 149, 130, 203, 83, 149, 204, 154, 58,
                32, 192, 118, 144, 129, 178, 83, 253, 8, 199, 161, 128>>,
        ?price_oracle_refresh_interval => 10,
        ?reward_version => 5,
        ?rewards_txn_version => 2,
        ?sc_causality_fix => 1,
        ?sc_gc_interval => 10,
        ?sc_grace_blocks => 10,
        ?sc_open_validation_bugfix => 1,
        ?sc_overcommit => 2,
        ?sc_version => 2,
        ?securities_percent => 0.34,
        ?snapshot_interval => 720,
        ?snapshot_version => 1,
        ?stake_withdrawal_cooldown => 250000,
        ?stake_withdrawal_max => 60,
        ?staking_fee_txn_add_gateway_v1 => 4000000,
        ?staking_fee_txn_assert_location_v1 => 1000000,
        ?staking_fee_txn_oui_v1 => 10000000,
        ?staking_fee_txn_oui_v1_per_address => 10000000,
        ?staking_keys =>
            <<33, 1, 37, 193, 104, 249, 129, 155, 16, 116, 103, 223, 160, 89, 196, 199, 11, 94, 109,
                49, 204, 84, 242, 3, 141, 250, 172, 153, 4, 226, 99, 215, 122, 202, 33, 1, 90, 111,
                210, 126, 196, 168, 67, 148, 63, 188, 231, 78, 255, 150, 151, 91, 237, 189, 148, 99,
                248, 41, 4, 103, 140, 225, 49, 117, 68, 212, 132, 113, 33, 1, 81, 215, 107, 13, 100,
                54, 92, 182, 84, 235, 120, 236, 201, 115, 77, 249, 2, 33, 68, 206, 129, 109, 248,
                58, 188, 53, 45, 34, 109, 251, 217, 130, 33, 1, 251, 174, 74, 242, 43, 25, 156, 188,
                167, 30, 41, 145, 14, 91, 0, 202, 115, 173, 26, 162, 174, 205, 45, 244, 46, 171,
                200, 191, 85, 222, 98, 120, 33, 1, 253, 88, 22, 88, 46, 94, 130, 1, 58, 115, 46,
                153, 194, 91, 1, 57, 194, 165, 181, 225, 251, 12, 13, 104, 171, 131, 151, 164, 83,
                113, 147, 216, 33, 1, 6, 76, 109, 192, 213, 45, 64, 27, 225, 251, 102, 247, 132, 42,
                154, 145, 70, 61, 127, 106, 188, 70, 87, 23, 13, 91, 43, 28, 70, 197, 41, 91, 33, 1,
                53, 200, 215, 84, 164, 84, 136, 102, 97, 157, 211, 75, 206, 229, 73, 177, 83, 153,
                199, 255, 43, 180, 114, 30, 253, 206, 245, 194, 79, 156, 218, 193, 33, 1, 229, 253,
                194, 42, 80, 229, 8, 183, 20, 35, 52, 137, 60, 18, 191, 28, 127, 218, 234, 118, 173,
                23, 91, 129, 251, 16, 39, 223, 252, 71, 165, 120, 33, 1, 54, 171, 198, 219, 118,
                150, 6, 150, 227, 80, 208, 92, 252, 28, 183, 217, 134, 4, 217, 2, 166, 9, 57, 106,
                38, 182, 158, 255, 19, 16, 239, 147, 33, 1, 51, 170, 177, 11, 57, 0, 18, 245, 73,
                13, 235, 147, 51, 37, 187, 248, 125, 197, 173, 25, 11, 36, 187, 66, 9, 240, 61, 104,
                28, 102, 194, 66, 33, 1, 187, 46, 236, 46, 25, 214, 204, 51, 20, 191, 86, 116, 0,
                174, 4, 247, 132, 145, 22, 83, 66, 159, 78, 13, 54, 52, 251, 8, 143, 59, 191, 196>>,
        ?transfer_hotspot_stale_poc_blocks => 1200,
        ?txn_fee_multiplier => 5000,
        ?txn_fees => true,
        ?validator_liveness_grace_period => 50,
        ?validator_liveness_interval => 100,
        ?validator_minimum_stake => 1000000000000,
        ?validator_version => 1,
        ?var_gw_inactivity_threshold => 600,
        ?vars_commit_delay => 1,
        ?witness_redundancy => 4,
        ?witness_refresh_interval => 200,
        ?witness_refresh_rand_n => 1000
    }.

gen_locations(Addresses) ->
    lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I / 50}, 13) | Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ).

start_blockchain(Config, GenesisVars) ->
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Curve = ?config(dkg_curve, Config),
    NumConsensusMembers = ?config(num_consensus_members, Config),

    #{secret := Priv, public := Pub} =
    Keys =
    libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = make_vars(Keys, GenesisVars),
    InitialPayments = gen_payments(Addresses),
    Locations = gen_locations(Addresses),
    InitialGws = gen_gateways(Addresses, Locations),
    Txns = InitialVars ++ InitialPayments ++ InitialGws,

    {ok, DKGCompletedNodes} = initial_dkg(
                                Miners,
                                Txns,
                                Addresses,
                                NumConsensusMembers,
                                Curve
                               ),
    %% integrate genesis block
    _GenesisLoadResults = integrate_genesis_block(
                            hd(DKGCompletedNodes),
                            Miners -- DKGCompletedNodes
                           ),
    {ConsensusMiners, NonConsensusMiners} = miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    MinerHts = pmap(
                 fun(M) ->
                         Ch = ct_rpc:call(M, blockchain_worker, blockchain, [], 2000),
                         {ok, Ht} = ct_rpc:call(M, blockchain, height, [Ch], 2000),
                         {M, Ht}
                 end, Miners),

    %% check that all miners are booted and have genesis block
    true = lists:all(
             fun({_, Ht}) ->
                     Ht == 1
             end,
             MinerHts),

    [
     {master_key, {Priv, Pub}},
     {consensus_miners, ConsensusMiners},
     {non_consensus_miners, NonConsensusMiners}
     | Config
    ].

