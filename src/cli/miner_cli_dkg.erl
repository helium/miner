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
                  dkg_status_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  dkg_cmd(),
                  dkg_status_cmd()
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
