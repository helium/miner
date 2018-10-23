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
                  hbbft_skip_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  hbbft_cmd(),
                  hbbft_status_cmd(),
                  hbbft_skip_cmd()
                 ]).
%%
%% hbbft
%%

hbbft_usage() ->
    [["hbbft"],
     ["miner hbbft commands\n\n",
      "  hbbft status           - Display hbbft status.\n"
      "  hbbft skip             - Skip current hbbft round.\n"
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
