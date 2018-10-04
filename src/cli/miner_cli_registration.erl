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
      "  register gw <Txn> <P2PAddr>- Register the gateway.\n"
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
     [["register", "gw", '*', '*'], [], [], fun register_gw/3]
    ].

register_gw_usage() ->
    [["register", "gw"],
     ["register gw <Txn> <P2PAddr> \n\n",
      "  Register the gw with P2PAddr.\n\n"
     ]
    ].

register_gw(["register", "gw", Txn, Addr], [], []) ->
    case (catch libp2p_crypto:p2p_to_address(Addr)) of
        {'EXIT', _Reason} ->
            usage;
        NodeAddr when is_binary(NodeAddr) ->
            miner:register_gw(base58:base58_to_binary(Txn), NodeAddr),
            [clique_status:text("ok")];
        _ ->
            usage
    end;
register_gw([_, _, _], [], []) ->
    usage.
