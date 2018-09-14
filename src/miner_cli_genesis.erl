%%%-------------------------------------------------------------------
%% @doc miner_cli_genesis
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_genesis).

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
                   genesis_usage(),
                   genesis_create_usage(),
                   genesis_load_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   genesis_cmd(),
                   genesis_create_cmd(),
                   genesis_load_cmd()
                  ]).
%%
%% genesis
%%

genesis_usage() ->
    [["genesis"],
     ["miner genesis commands\n\n",
      "  genesis create <addrs> - Create genesis block.\n",
      "  genesis load <genesis_block>  - Load genesis block for this peer.\n"
     ]
    ].

genesis_cmd() ->
    [
     [["genesis"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% genesis create
%%

genesis_create_cmd() ->
    [
     [["genesis", "create", '*'], [], [], fun genesis_create/3]
    ].

genesis_create_usage() ->
    [["genesis", "create"],
     ["genesis create <addrs> \n\n",
      "  create a new genesis block.\n\n"
     ]
    ].

genesis_create(["genesis", "create", Addrs], [], []) ->
    List = lists:foldl(fun(Addr, Acc) ->
                               [Addr | Acc]
                       end, [], string:split(Addrs, ",", all)),
    miner:initial_dkg([libp2p_crypto:p2p_to_address(Addr) || Addr <- List]),
    [clique_status:text("ok")];
genesis_create([_, _, _], [], []) ->
    usage.

%%
%% genesis load
%%

genesis_load_cmd() ->
    [
     [["genesis", "load", '*'], [], [], fun genesis_load/3]
    ].

genesis_load_usage() ->
    [["genesis", "load"],
     ["genesis load <genesis_block> \n\n",
      "  load a new genesis block on the node.\n\n"
     ]
    ].

genesis_load(["genesis", "load", GenesisBlockFile], [], []) ->
    {ok, GenesisBlock} = miner_util:load_block_from_file(GenesisBlockFile),
    blockchain_worker:integrate_genesis_block(GenesisBlock),
    [clique_status:text("ok")];
genesis_load([], [], []) ->
    usage.
