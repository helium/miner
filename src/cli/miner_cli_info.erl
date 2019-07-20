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
                   info_in_consensus_usage(),
                   info_name_usage(),
                   info_block_age_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   info_cmd(),
                   info_height_cmd(),
                   info_in_consensus_cmd(),
                   info_name_cmd(),
                   info_block_age_cmd()
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
    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    Epoch =
    try integer_to_list(miner:election_epoch()) of
        E -> E
    catch _:_ ->
            io_lib:format("~p", [erlang:process_info(whereis(miner), current_stacktrace)])
    end,
    [clique_status:text(Epoch ++ "\t\t" ++ integer_to_list(Height))];
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
    [clique_status:text(atom_to_list(miner_consensus_mgr:in_consensus()))];
info_in_consensus([_, _, _], [], []) ->
    usage.

%%
%% info name
%%

info_name_cmd() ->
    [
     [["info", "name"], [], [], fun info_name/3]
    ].

info_name_usage() ->
    [["info", "name"],
     ["info name \n\n",
      "  Get name for this miner.\n\n"
     ]
    ].

info_name(["info", "name"], [], []) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())),
    [clique_status:text(Name)];
info_name([_, _, _], [], []) ->
    usage.

%%
%% info block_age
%%

info_block_age_cmd() ->
    [
     [["info", "block_age"], [], [], fun info_block_age/3]
    ].

info_block_age_usage() ->
    [["info", "block_age"],
     ["info block_age \n\n",
      "  Get age of the latest block in the chain, in seconds.\n\n"
     ]
    ].

info_block_age(["info", "block_age"], [], []) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Block} = blockchain:head_block(Chain),
    Age = erlang:system_time(seconds) - blockchain_block:time(Block),
    [clique_status:text(integer_to_list(Age))];
info_block_age([_, _, _], [], []) ->
    usage.

