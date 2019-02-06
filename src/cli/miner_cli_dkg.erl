%%%-------------------------------------------------------------------
%% @doc miner_cli_dkg
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_dkg).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(fun(Args) ->
                          apply(clique, register_usage, Args)
                  end,
                 [
                  dkg_usage(),
                  dkg_status_usage(),
                  dkg_queue_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  dkg_cmd(),
                  dkg_status_cmd(),
                  dkg_queue_cmd()
                 ]).
%%
%% dkg
%%

dkg_usage() ->
    [["dkg"],
     ["miner dkg commands\n\n",
      "  dkg status           - Display dkg status.\n"
     ]
    ].

dkg_cmd() ->
    [
     [["dkg"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% dkg status
%%

dkg_status_cmd() ->
    [
     [["dkg", "status"], [], [], fun dkg_status/3]
    ].

dkg_status_usage() ->
    [["dkg", "status"],
     ["dkg status \n\n",
      "  Display dkg status currently.\n\n"
     ]
    ].

dkg_status(["dkg", "status"], [], []) ->
    Text = clique_status:text(io_lib:format("~p", [miner:dkg_status()])),
    [Text];
dkg_status([], [], []) ->
    usage.

%%
%% dkg queue
%%

dkg_queue_cmd() ->
    [
     [["dkg", "queue"], [], [
                              {inbound, [{shortname, "i"}, {longname, "inbound"}, {datatype, {enum, [true, false]}}]},
                              {outbound, [{shortname, "o"}, {longname, "outbound"}, {datatype, integer}]}
                             ], fun dkg_queue/3]
    ].

dkg_queue_usage() ->
    [["dkg", "queue"],
     ["dkg queue \n\n",
      "  Summarize the dkg queue for this node\n"
      "  -i --inbound <boolean>\n"
      "  Show the queued inbound messages\n"
      "  -o --outbound <peer ID> \n"
      "  Show the queued outbound messages for <peer ID>\n"
     ]
    ].

dkg_queue(["dkg", "queue"], [], Flags) ->
    Queue = miner:relcast_queue(dkg_group),
    case proplists:get_value(inbound, Flags, false) of
        false ->
            case proplists:get_value(outbound, Flags) of
                undefined ->
                    Workers = maps:get(worker_info, miner:relcast_info(dkg_group), #{}),
                    %% just print a summary of the queue
                    [clique_status:table([[{destination, "inbound"},
                                           {count, integer_to_list(length(maps:get(inbound, Queue, [])))},
                                           {connected, "true"},
                                           {blocked, "false"},
                                           {in_flight, "0"},
                                           {connections, "0"},
                                           {last_take, "none"},
                                           {last_ack, 0}
                                          ]] ++
                                         [[{destination, integer_to_list(K)},
                                           {count, integer_to_list(length(V))},
                                           {connected, atom_to_list(not (maps:get(stream_info, maps:get(info, maps:get(K, Workers))) == undefined))},
                                           {blocked, atom_to_list(not (maps:get(ready, maps:get(K, Workers))))},
                                           {in_flight, integer_to_list(maps:get(in_flight, maps:get(K, Workers)))},
                                           {connects, integer_to_list(maps:get(connects, maps:get(K, Workers)))},
                                           {last_take, atom_to_list(maps:get(last_take, maps:get(K, Workers)))},
                                           {last_ack, integer_to_list(erlang:system_time(second) - maps:get(last_ack, maps:get(K, Workers)))}
                                          ] ||
                                          {K, V} <- maps:to_list(maps:get(outbound, Queue, #{}))])];
                PeerID when is_integer(PeerID) ->
                            %% print the outbound messages for this peer
                            Msgs = maps:get(PeerID, maps:get(outbound, Queue, #{}), []),
                            [clique_status:table([[{message, lists:flatten(io_lib:format("~p", [Msg]))}] || Msg <- Msgs])];
                _ -> usage
            end;
        _ ->
            Msgs = maps:get(inbound, Queue, []),
            [clique_status:table([[{message, lists:flatten(io_lib:format("~p", [Msg]))}] || Msg <- Msgs])]
    end;
dkg_queue([], [], []) ->
    usage.
