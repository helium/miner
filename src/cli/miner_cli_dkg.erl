%%%-------------------------------------------------------------------
%% @doc miner_cli_dkg
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_dkg).

-behavior(clique_handler).

-include_lib("blockchain/include/blockchain_vars.hrl").

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
                  dkg_queue_usage(),
                  dkg_running_usage(),
                  dkg_next_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  dkg_cmd(),
                  dkg_status_cmd(),
                  dkg_queue_cmd(),
                  dkg_running_cmd(),
                  dkg_next_cmd()
                 ]).
%%
%% dkg
%%

dkg_usage() ->
    [["dkg"],
     ["miner dkg commands\n\n",
      "  dkg status           - Display dkg status.\n"
      "  dkg queue            - Display dkg queue.\n"
      "  dkg running          - Display the running dkg group on a non-dkg mode.\n"
      "  dkg next             - Display the next block at which an election will take place.\n"
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
    Status =
        try miner_consensus_mgr:dkg_status() of
            Stat -> Stat
        catch _:_ ->
                not_running
        end,
    Text = clique_status:text(io_lib:format("~p", [Status])),
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
                              {outbound, [{shortname, "o"}, {longname, "outbound"}, {datatype, integer}]},
                              {verbose, [{shortname, "v"}, {longname, "verbose"}]}
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
      " -v --verbose\n"
      "  Show extra information"
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
dkg_queue([], [], []) ->
    usage.

dkg_running_cmd() ->
    [
     [["dkg", "running"], [],
      [
       {plain, [{shortname, "p"}, {longname, "plain"}]}
      ], fun dkg_running/3]
    ].

dkg_running_usage() ->
    [["dkg", "running"],
     ["dkg queue \n\n",
      "  Display the currently running dkg group from any node\n"
      " -p --plain\n"
      "  display only the animal names"
     ]
    ].

dkg_running(["dkg", "running"], [], Flags) ->
    %% calculate the current election start height
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Curr} = blockchain_ledger_v1:current_height(Ledger),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),
    {ok, N} = blockchain:config(?num_consensus_members, Ledger),

    #{start_height := EpochStart} = blockchain_election:election_info(Ledger),
    Height = EpochStart + ElectionInterval,
    Diff = Curr - Height,
    Delay = max(0, (Diff div RestartInterval) * RestartInterval),
    case Curr >= Height of
        false ->
            [clique_status:text("not running")];
        _ ->
            {ok, Block} = blockchain:get_block(Height+Delay, Chain),
            Hash = blockchain_block:hash_block(Block),
            ConsensusAddrs = blockchain_election:new_group(Ledger, Hash, N, Delay),
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
            end
    end;
dkg_running([], [], []) ->
    usage.

dkg_next_cmd() ->
    [
     [["dkg", "next"], [], [], fun dkg_next/3]
    ].

dkg_next_usage() ->
    [["dkg", "next"],
     ["dkg next \n\n",
      "  Show the block height of the current election, or if it is running\n"
      "  height of the next restart\n"
     ]
    ].

dkg_next(["dkg", "next"], [], _Flags) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, Curr} = blockchain_ledger_v1:current_height(Ledger),
    {ok, ElectionInterval} = blockchain:config(?election_interval, Ledger),
    {ok, RestartInterval} = blockchain:config(?election_restart_interval, Ledger),

    #{start_height := EpochStart} = blockchain_election:election_info(Ledger),
    Height = EpochStart + ElectionInterval,
    Diff = Curr - Height,
    Delay = max(0, (Diff div RestartInterval) * RestartInterval),
    case Curr >= Height of
        false ->
            [clique_status:text(["next election: ", integer_to_list(Height),
                                 " in ", integer_to_list(Height - Curr), " blocks."])];
        _ ->
            NextRestart = Height + Delay + RestartInterval,
            [clique_status:text(["running, next restart: ", integer_to_list(NextRestart),
                                 " in ", integer_to_list(NextRestart - Curr), " blocks."])]
    end;
dkg_next([], [], []) ->
    usage.
