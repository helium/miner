%%%-------------------------------------------------------------------
%% @doc miner_cli_status
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_status).

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
                   status_usage(),
                   status_height_usage(),
                   status_in_consensus_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   status_cmd(),
                   status_height_cmd(),
                   status_in_consensus_cmd()
                  ]).
%%
%% status
%%

status_usage() ->
    [["status"],
     ["miner status commands\n\n",
      "  status height - Get height of the blockchain for this miner.\n",
      "  status in_consensus - Show if this miner is in the consensus_group.\n"
     ]
    ].

status_cmd() ->
    [
     [["status"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% status height
%%

status_height_cmd() ->
    [
     [["status", "height"], [], [], fun status_height/3]
    ].

status_height_usage() ->
    [["status", "height"],
     ["status height \n\n",
      "  Get height of the blockchain for this miner.\n\n"
     ]
    ].

status_height(["status", "height"], [], []) ->
    [clique_status:text(integer_to_list(blockchain_worker:height()))];
status_height([_, _, _], [], []) ->
    usage.


%%
%% status in_consensus
%%

status_in_consensus_cmd() ->
    [
     [["status", "in_consensus"], [], [], fun status_in_consensus/3]
    ].

status_in_consensus_usage() ->
    [["status", "in_consensus"],
     ["status in_consensus \n\n",
      "  Get whether this miner is in the consensus group.\n\n"
     ]
    ].

status_in_consensus(["status", "in_consensus"], [], []) ->
    [clique_status:text(atom_to_list(miner:in_consensus_group()))];
status_in_consensus([_, _, _], [], []) ->
    usage.
