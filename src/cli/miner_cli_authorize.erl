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
                   authorize_gw_usage(),
                   authorize_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   authorize_gw_cmd(),
                   authorize_cmd()
                  ]).


%%
%% authorize
%%

authorize_usage() ->
    [["authorize"],
     ["miner authorize commands\n\n",
      "   authorize gw    - Send authorization request for adding a gw to a given p2paddress\n"
     ]
    ].


authorize_cmd() ->
    [
     ["authorize", [], [], fun(_, _, _) -> usage end]
    ].

%%
%% authorize gw
%%
authorize_gw_cmd() ->
    [
     [
      ["authorize", "gw"], '_', [
                                 {address, [{shortname, "a"}, {longname, "address"}]},
                                 {request, [{shortname, "r"}, {longname, "request"}]},
                                 {token, [{shortname, "t"}, {longname, "token"}]}
                                ], fun authorize_gw/3
     ]
    ].

authorize_gw_usage() ->
    [["authorize", "gw"],
     ["miner authorize gw\n\n",
      "  Send authorization request to the wallet for adding a gw.\n",
      "  Use key=value args to set options.\n\n",
      "Required:\n\n"
      "  -a, --address [P2PAddress]\n",
      "   The p2paddress of the node to dial\n",
      "  -r, --request [AddGwRequestTxn]\n",
      "   The partial add_gateway_request txn. Use ledger add_gateway_request <OwnerAddress> to obtain request.\n",
      "  -t, --token [Token]\n",
      "   The token obtained from the QR code from wallet app\n"
     ]
    ].

authorize_gw(_CmdBase, _, []) ->
    usage;
authorize_gw(_CmdBase, _Keys, Flags) ->
    case (catch authorize_gw_helper(Flags)) of
        {'EXIT', _Reason} ->
            usage;
        ok ->
            [clique_status:text("ok")];
        _ -> usage
    end.

authorize_gw_helper(Flags) ->
    Address = libp2p_crypto:p2p_to_address(clean(proplists:get_value(address, Flags))),
    AddGwRequestTxn = base58:base58_to_binary(clean(proplists:get_value(request, Flags))),
    Token = clean(proplists:get_value(token, Flags)),
    miner:send_authorization_request(AddGwRequestTxn, Token, Address).

%% NOTE: I noticed that giving a shortname to the flag would end up adding a leading "="
%% Presumably none of the flags would be _having_ a leading "=" intentionally!
clean(String) ->
    case string:split(String, "=", leading) of
        [[], S] -> S;
        [S] -> S;
        _ -> error
    end.
