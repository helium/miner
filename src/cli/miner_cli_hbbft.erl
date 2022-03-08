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
                  hbbft_queue_usage(),
                  hbbft_group_usage(),
                  hbbft_perf_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  hbbft_cmd(),
                  hbbft_status_cmd(),
                  hbbft_skip_cmd(),
                  hbbft_queue_cmd(),
                  hbbft_group_cmd(),
                  hbbft_perf_cmd()
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
      "  hbbft group            - Display current hbbft group.\n"
      "  hbbft perf             - Show performance of current group members.\n"
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
                              {outbound, [{shortname, "o"}, {longname, "outbound"}, {datatype, integer}]},
                              {verbose, [{shortname, "v"}, {longname, "verbose"}]}
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
      " -v --verbose\n"
      "  Show extra information\n"
     ]
    ].

hbbft_queue(["hbbft", "queue"], [], Flags) ->
    Queue = miner:relcast_queue(consensus_group),
    case proplists:get_value(inbound, Flags, false) of
        false ->
            case proplists:get_value(outbound, Flags) of
                undefined ->
                    Workers = maps:get(worker_info, miner:relcast_info(consensus_group), #{}),
                    %% just print a summary of the queue
                    [clique_status:table([[{destination, "inbound"} ] ++
                                           [{address, ""} || lists:keymember(verbose, 1, Flags)] ++
                                           [{name, ""},
                                           {count, integer_to_list(length(maps:get(inbound, Queue, [])))},
                                           {connected, "true"},
                                           {blocked, "false"},
                                           {in_flight, "0"},
                                           {connections, "0"},
                                           {last_take, "none"},
                                           {last_ack, 0}
                                          ]] ++
                                         [[{destination, integer_to_list(K)}] ++
                                           [{address, maps:get(address, maps:get(K, Workers))} || lists:keymember(verbose, 1, Flags)] ++
                                           [{name, element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(libp2p_crypto:p2p_to_pubkey_bin(maps:get(address, maps:get(K, Workers))))))},
                                           {count, integer_to_list(length(V))},
                                           {connected, atom_to_list((maps:get(connected, maps:get(K, Workers)))) },
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
hbbft_queue([], [], []) ->
    usage.

hbbft_group_cmd() ->
    [
     [["hbbft", "group"], [],
      [
       {plain, [{shortname, "p"}, {longname, "plain"}]}
      ], fun hbbft_group/3]
    ].

hbbft_group_usage() ->
    [["hbbft", "group"],
     ["hbbft queue \n\n",
      "  Display the currently running hbbft group from any node\n"
      " -p --plain\n"
      "  display only the animal names"
     ]
    ].

hbbft_group(["hbbft", "group"], [], Flags) ->
    %% calculate the current election start height
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    case proplists:get_value(plain, Flags, false) of
        false ->
            [clique_status:table(
               [[{index, integer_to_list(Idx)},
                 {name, element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(A)))},
                 {address, libp2p_crypto:pubkey_bin_to_p2p(A)}]
                || {Idx, A} <- lists:zip(lists:seq(1, length(ConsensusAddrs)),
                                         ConsensusAddrs)])];
        _ ->
            L = lists:map(fun(X) ->
                                  {ok, A} = erl_angry_purple_tiger:animal_name(
                                              libp2p_crypto:bin_to_b58(X)),
                                  io_lib:format("~s~n", [A])
                          end, ConsensusAddrs),
            [clique_status:text(L)]
    end;
hbbft_group([], [], []) ->
    usage.

hbbft_perf_cmd() ->
    [
     [["hbbft", "perf"], [],
      [
       {verbose, [{shortname, "v"}, {longname, "verbose"}]}
      ], fun hbbft_perf/3]
    ].

hbbft_perf_usage() ->
    [["hbbft", "perf"],
     ["hbbft queue \n\n",
      "  Display the performance of the current hbbft group\n"
      " -v --verbose\n"
      "  Show extra information\n"
     ]
    ].

hbbft_perf(["hbbft", "perf"], [], Flags) ->
    #{
        consensus_members := ConsensusMembers,
        bba_totals := BBATotals,
        seen_totals := SeenTotals,
        max_seen := MaxSeen,
        group_with_penalties := GroupWithPenalties,
        election_start_height := ElectionStart,
        epoch_start_height := EpochStart,
        current_height := CurrentHeight
    } = miner_util:hbbft_perf(),
    PostElectionHeight = ElectionStart + 1,
    BlocksSince = CurrentHeight + 1 - EpochStart,
    [clique_status:table(
       [[{name, element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(A)))} ] ++
            [ {address, libp2p_crypto:pubkey_bin_to_p2p(A)} || lists:keymember(verbose, 1, Flags)] ++
            [
             {bba_completions, io_lib:format("~b/~b", [element(2, maps:get(A, BBATotals)), BlocksSince])},
             {seen_votes, io_lib:format("~b/~b", [element(2, maps:get(A, SeenTotals)), MaxSeen])},
             {last_bba, CurrentHeight - max(PostElectionHeight, element(1, maps:get(A, BBATotals)))},
             {last_seen, CurrentHeight - max(PostElectionHeight, element(1, maps:get(A, SeenTotals)))},
             {tenure, io_lib:format("~.2f", [element(2, element(2, lists:keyfind(A, 1, GroupWithPenalties)))])},
             {penalty, io_lib:format("~.2f", [element(1, element(2, lists:keyfind(A, 1, GroupWithPenalties)))])}
            ] || A <- ConsensusMembers])];
hbbft_perf([], [], []) ->
    usage.
