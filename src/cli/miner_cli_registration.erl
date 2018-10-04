%%%-------------------------------------------------------------------
%% @doc miner_cli_registration
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_registration).

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
                   register_usage(),
                   register_gw_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   register_cmd(),
                   register_gw_cmd()
                  ]).
%%
%% info
%%

register_usage() ->
    [["register"],
     ["miner register commands\n\n",
      "  register gw <P2PAddr> <Txn> <Token> - Register the gateway.\n"
     ]
    ].

register_cmd() ->
    [
     [["register"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% register gw
%%

register_gw_cmd() ->
    [
     [["register", "gw", '*', '*', '*'], [], [], fun register_gw/3]
    ].

register_gw_usage() ->
    [["register", "gw"],
     ["register gw <P2PAddr> <Txn> <Token> \n\n",
      "  Register the gw with P2PAddr.\n\n"
     ]
    ].

register_gw(["register", "gw", Addr, Txn, Token], [], []) ->
    case (catch libp2p_crypto:p2p_to_address(Addr)) of
        {'EXIT', _Reason} ->
            io:format("EXIT, Reason: ~p~n", [_Reason]),
            usage;
        NodeAddr when is_binary(NodeAddr) ->
            io:format("NodeAddr: ~p~n", [NodeAddr]),
            miner:register_gw(base58:base58_to_binary(Txn), Token, NodeAddr),
            [clique_status:text("ok")];
        Other ->
            io:format("other: ~p~n", [Other]),
            usage
    end;
register_gw(_, [], []) ->
    io:format("none"),
    usage.
