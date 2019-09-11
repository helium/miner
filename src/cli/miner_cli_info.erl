%%%-------------------------------------------------------------------
%% @doc miner_cli_info
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_info).

-behavior(clique_handler).

-export([register_cli/0]).

-export([get_info/0]).

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
                   info_block_age_usage(),
                   info_p2p_status_usage()
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
                   info_block_age_cmd(),
                   info_p2p_status_cmd()
                  ]).
%%
%% info
%%

info_usage() ->
    [["info"],
     ["miner info commands\n\n",
      "  info height - Get height of the blockchain for this miner.\n",
      "  info in_consensus - Show if this miner is in the consensus_group.\n"
      "  name - Shows the name of this miner.\n"
      "  block_age - Get age of the latest block in the chain, in seconds.\n"
      "  p2p_status - Shows key peer connectivity status of this miner.\n"
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
      "  The first number is the current election epoch, and the second is\n"
      "  the block height.  If the second number is displayed with an asterisk (*)\n"
      "  this node has yet to sync past the assumed valid hash in the node config.\n\n"
     ]
    ].

get_info() ->
    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {Epoch, _} = blockchain_block_v1:election_info(HeadBlock),
    {Height, SyncHeight, Epoch}.

info_height(["info", "height"], [], []) ->
    {Height, SyncHeight, Epoch0} = get_info(),
    Epoch = integer_to_list(Epoch0),

    case SyncHeight == Height of
        true ->
            [clique_status:text(Epoch ++ "\t\t" ++ integer_to_list(Height))];
        false ->
            [clique_status:text([Epoch, "\t\t", integer_to_list(Height), "\t\t", integer_to_list(SyncHeight), "*"])]
    end;
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
    Age = miner:block_age(),
    [clique_status:text(integer_to_list(Age))];
info_block_age([_, _, _], [], []) ->
    usage.

%%
%% info p2p_status
%%

info_p2p_status_cmd() ->
    [
     [["info", "p2p_status"], [], [], fun info_p2p_status/3]
    ].

info_p2p_status_usage() ->
    [["info", "p2p_status"],
     ["info p2p_status \n\n",
      "  Returns peer connectivity checks for this miner.\n\n"
     ]
    ].

info_p2p_status(["info", "p2p_status"], [], []) ->
    StatusResults = miner:p2p_status(),
    FormatResult = fun({Name, Result}) ->
                           [{name, Name}, {result, Result}]
                   end,
    [clique_status:table(lists:map(FormatResult, StatusResults))];
info_p2p_status([_, _, _], [], []) ->
    usage.
