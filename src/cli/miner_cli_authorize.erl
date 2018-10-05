%%%-------------------------------------------------------------------
%% @doc miner_cli_authorize
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_authorize).

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
                   authorize_gw_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   authorize_gw_cmd()
                  ]).

%%
%% authorize gw
%%
authorize_gw(["authorize", "gw", Addr, Txn, Token], [], []) ->
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
authorize_gw([_, _, _, _, _], [], []) ->
    io:format("None~n"),
    usage.

authorize_gw_usage() ->
    [["authorize", "gw"],
     ["authorize gw <P2PAddress> <AddRequestTxn> <Token>\n\n",
      "  Send gw authorization request to <P2PAddress>.\n\n"
     ]
    ].

authorize_gw_cmd() ->
    [
     [["authorize", "gw", '*', '*', '*'], [], [], fun authorize_gw/3]
    ].
