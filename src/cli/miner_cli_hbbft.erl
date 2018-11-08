%%%-------------------------------------------------------------------
%% @doc miner_cli_hbbft
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_hbbft).

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
                  hbbft_usage(),
                  hbbft_status_usage(),
                  hbbft_skip_usage(),
                  hbbft_queue_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  hbbft_cmd(),
                  hbbft_status_cmd(),
                  hbbft_skip_cmd(),
                  hbbft_queue_cmd()
                 ]).
%%
%% hbbft
%%

hbbft_usage() ->
    [["hbbft"],
     ["miner hbbft commands\n\n",
      "  hbbft status           - Display hbbft status.\n"
      "  hbbft queue            - Display hbbft message queue.\n"
      "  hbbft skip             - Skip current hbbft round.\n"
      "  hbbft queue            - Show hbbft queued messages.\n"
     ]
    ].

hbbft_cmd() ->
    [
     [["hbbft"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% hbbft status
%%

hbbft_status_cmd() ->
    [
     [["hbbft", "status"], [], [], fun hbbft_status/3]
    ].

hbbft_status_usage() ->
    [["hbbft", "status"],
     ["hbbft status \n\n",
      "  Display hbbft status currently.\n\n"
     ]
    ].

hbbft_status(["hbbft", "status"], [], []) ->
    Text = clique_status:text(io_lib:format("~p", [miner:hbbft_status()])),
    [Text];
hbbft_status([], [], []) ->
    usage.


%%
%% hbbft skip
%%

hbbft_skip_cmd() ->
    [
     [["hbbft", "skip"], [], [], fun hbbft_skip/3]
    ].

hbbft_skip_usage() ->
    [["hbbft", "skip"],
     ["hbbft skip \n\n",
      "  Skip current hbbft round.\n\n"
     ]
    ].

hbbft_skip(["hbbft", "skip"], [], []) ->
    Text = clique_status:text(io_lib:format("~p", [miner:hbbft_skip()])),
    [Text];
hbbft_skip([], [], []) ->
    usage.

%%
%% hbbft queue
%%

hbbft_queue_cmd() ->
    [
     [["hbbft", "queue"], [], [
                              {inbound, [{shortname, "i"}, {longname, "inbound"}, {datatype, {enum, [true, false]}}]},
                              {outbound, [{shortname, "o"}, {longname, "outbound"}, {datatype, integer}]}
                             ], fun hbbft_queue/3]
    ].

hbbft_queue_usage() ->
    [["hbbft", "queue"],
     ["hbbft queue \n\n",
      "  Summarize the HBBFT queue for this node\n"
      "  -i --inbound <boolean>\n"
      "  Show the queued inbound messages\n"
      "  -o --outbound <peer ID> \n"
      "  Show the queued outbound messages for <peer ID>\n"
     ]
    ].

hbbft_queue(["hbbft", "queue"], [], Flags) ->
    Queue = miner:relcast_queue(),
    case proplists:get_value(inbound, Flags, false) of
        false ->
            case proplists:get_value(outbound, Flags) of
                undefined ->
                    Workers = maps:get(worker_info, miner:relcast_info(), #{}),
                    %% just print a summary of the queue
                    [clique_status:table([[{destination, "inbound"},
                                           {count, integer_to_list(length(maps:get(inbound, Queue, [])))},
                                           {connected, "true"},
                                           {pending_data, "false"}
                                          ]] ++
                                         [[{destination, integer_to_list(K)},
                                           {count, integer_to_list(length(V))},
                                           {connected, atom_to_list(not (maps:get(stream_info, maps:get(info, maps:get(K, Workers))) == undefined))},
                                           {blocked, atom_to_list(not (maps:get(msg_key, maps:get(K, Workers)) == undefined))}
                                          ] ||
                                          {K, V} <- maps:to_list(maps:get(outbound, Queue, #{}))])];
                PeerID when is_integer(PeerID) ->
                            %% print the outbound messages for this peer
                            Msgs = maps:get(PeerID, maps:get(outbound, Queue, #{}), []),
                            [clique_status:table([[{message, lists:flatten(io_lib:format("~p", [Msg]))}] || Msg <- Msgs])];
                _ -> usage
            end;
        true ->
            Msgs = maps:get(inbound, Queue, []),
            [clique_status:table([[{message, lists:flatten(io_lib:format("~p", [Msg]))}] || Msg <- Msgs])]
    end;
hbbft_queue([], [], []) ->
    usage.
