-module(miner_ct_utils).

-export([pmap/2,
         wait_until/1,
         wait_until/3,
         wait_until_disconnected/2,
         start_node/3,
         partition_cluster/2,
         heal_cluster/2,
         connect/1,
		 count/2
        ]).

pmap(F, L) ->
    Parent = self(),
    lists:foldl(
      fun(X, N) ->
              spawn_link(fun() ->
                                 Parent ! {pmap, N, F(X)}
                         end),
              N+1
      end, 0, L),
    L2 = [receive {pmap, N, R} -> {N,R} end || _ <- L],
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    L3.

wait_until(Fun) ->
    wait_until(Fun, 40, 100).
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
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
