%%%-------------------------------------------------------------------
%% @doc miner_cli_info
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_info).

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
                   info_usage(),
                   info_height_usage(),
                   info_in_consensus_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   info_cmd(),
                   info_height_cmd(),
                   info_in_consensus_cmd()
                  ]).
%%
%% info
%%

info_usage() ->
    [["info"],
     ["miner info commands\n\n",
      "  info height - Get height of the blockchain for this miner.\n",
      "  info in_consensus - Show if this miner is in the consensus_group.\n"
     ]
    ].

info_cmd() ->
    [
     [["info"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% info height
%%

info_height_cmd() ->
    [
     [["info", "height"], [], [], fun info_height/3]
    ].

info_height_usage() ->
    [["info", "height"],
     ["info height \n\n",
      "  Get height of the blockchain for this miner.\n\n"
     ]
    ].

info_height(["info", "height"], [], []) ->
    [clique_status:text(integer_to_list(blockchain_worker:height()))];
info_height([_, _, _], [], []) ->
    usage.


%%
%% info in_consensus
%%

info_in_consensus_cmd() ->
    [
     [["info", "in_consensus"], [], [], fun info_in_consensus/3]
    ].

info_in_consensus_usage() ->
    [["info", "in_consensus"],
     ["info in_consensus \n\n",
      "  Get whether this miner is in the consensus group.\n\n"
     ]
    ].

info_in_consensus(["info", "in_consensus"], [], []) ->
    [clique_status:text(atom_to_list(miner:in_consensus()))];
info_in_consensus([_, _, _], [], []) ->
    usage.
