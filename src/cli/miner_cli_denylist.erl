%%%-------------------------------------------------------------------
%% @doc miner_cli_denylist
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_denylist).

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
                  denylist_usage(),
                  denylist_status_usage(),
                  denylist_check_usage()
                 ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                 [
                  denylist_cmd(),
                  denylist_status_cmd(),
                  denylist_check_cmd()
                 ]).
%%
%% denylist
%%

denylist_usage() ->
    [["denylist"],
     ["miner denylist commands\n\n",
      "  denylist status           - Display status of denylist.\n"
      "  denylist check <address>  - Check if address is on denylist.\n"
     ]
    ].

denylist_cmd() ->
    [
     [["denylist"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% denylist status
%%

denylist_status_cmd() ->
    [
     [["denylist", "status"], [], [], fun denylist_status/3]
    ].

denylist_status_usage() ->
    [["denylist", "status"],
     ["denylist status\n\n",
      "  Display status of denylist.\n\n"
     ]
    ].

denylist_status(["denylist", "status"], [], []) ->
    Text = try miner_poc_denylist:get_version() of 
        {ok, Version} -> 
            clique_status:text(io_lib:format("Denylist version ~p loaded", [Version]))
    catch _:_ ->
        clique_status:text(io_lib:format("No denylist loaded",[]))
    end,
    [Text];
denylist_status([], [], []) ->
    usage.


%%
%% denylist check
%%

denylist_check_cmd() ->
    [
     [["denylist", "check", '*'], [], [], fun denylist_check/3]
    ].

denylist_check_usage() ->
    [["denylist", "check"],
     ["denylist check <address>\n\n",
      "  Check if address is on denylist.\n\n"
     ]
    ].

denylist_check(["denylist", "check", Address], [], []) ->
    Result =
        try miner_poc_denylist:check(libp2p_crypto:b58_to_bin(Address)) of
            R -> R
        catch _:_ ->
            invalid_address
        end,
    Text = clique_status:text(io_lib:format("~p", [Result])),
    [Text];
denylist_check([], [], []) ->
    usage.
