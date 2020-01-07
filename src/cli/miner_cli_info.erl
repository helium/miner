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
                   info_p2p_status_usage(),
                   info_summary_usage()
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
                   info_p2p_status_cmd(),
                   info_summary_cmd()
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
      "  summary - Get a collection of key data points for this miner.\n"
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

get_p2p_info() ->
    StatusResults = miner:p2p_status(),
    FormatResult = fun({Name, Result}) ->
                           [{name, Name}, {result, Result}]
                   end,
    {FormatResult, StatusResults}.

info_p2p_status(["info", "p2p_status"], [], []) ->
    {FormatResult, StatusResults} = get_p2p_info(),
    [clique_status:table(lists:map(FormatResult, StatusResults))];
info_p2p_status([_, _, _], [], []) ->
    usage.


%%
%% info summary
%%

info_summary_cmd() ->
    [
     [["info", "summary"], [], [], fun info_summary/3],
     [["info", "summary"], [],
      [{error_count, [  {shortname, "e"},
                        {longname, "error_count"}]}
      ], fun info_summary/3]
    ].

info_summary_usage() ->
    [["info", "summary"],
     ["info summary \n\n",
      "  Get a collection of key data points for this miner.\n\n"
      "  Included is the last 5 error log entries for 3 categories: Transactions, POCs and Other errors\n\n"
      "Options\n\n"
      "  -e, --error_count <count> "
      "    Override the default count of 5 log entries per category\n\n"
     ]
    ].

get_summary_info(ErrorCount)->
    PubKey = blockchain_swarm:pubkey_bin(),
    {ok, MinerName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKey)),
    {ok, Macs} = get_mac_addrs(),
    BlockAge = miner:block_age(),
    Uptime = get_uptime(),
    {ok, POCErrors, TxnErrors, GenErrors} = get_log_errors(ErrorCount),

    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {Epoch, _} = blockchain_block_v1:election_info(HeadBlock),
    SyncHeight0 = format_sync_height(SyncHeight, Height),

    Swarm = blockchain_swarm:swarm(),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    PeerBookEntryCount = length(libp2p_peerbook:values(Peerbook)),

    FirmwareVersion = get_firmware_version(),

    GWInfo = get_gateway_info(Chain, PubKey),

    GeneralInfo =
        [   {"miner name", MinerName},
            {"mac addresses", Macs},
            {"block age", BlockAge},
            {"epoch", Epoch},
            {"height", Height},
            {"sync height", SyncHeight0},
            {"uptime", Uptime},
            {"peer book size", PeerBookEntryCount },
            {"firmware version", FirmwareVersion},
            {"gateway details", GWInfo}
        ],
    {GeneralInfo, POCErrors, TxnErrors, GenErrors}.

info_summary(["info", "summary"], [], []) ->
    do_info_summary("5");
info_summary(["info", "summary"], _Keys, [{error_count, Count}]) ->
    do_info_summary(Count);
info_summary(_CmdBase, _Keys, _Flags) ->
    usage.

do_info_summary(ErrorCount) ->
    {GeneralInfo, POCErrorInfo, TxnErrorInfo, GenErrorInfo} = get_summary_info(ErrorCount),

    GeneralFormat =   fun({Name, Result}) ->
                            [{name, Name}, {result, Result}]
                      end,
    [   clique_status:text("\n********************\nMiner General Info\n********************\n"),
        clique_status:table(lists:map(GeneralFormat, GeneralInfo)),
        clique_status:text("\n********************\nMiner P2P Info\n********************\n"),
        hd(info_p2p_status(["info", "p2p_status"], [], [])),
        clique_status:text("\n********************\nMiner error log entries\n********************\n"),
        clique_status:list("***** Transaction related errors *****\n\n", TxnErrorInfo),
        clique_status:list( "***** POC related errors         *****\n\n", POCErrorInfo),
        clique_status:list( "***** General errors             *****\n\n", GenErrorInfo)

    ].


get_mac_addrs()->
    {ok, IFs} = inet:getifaddrs(),
    Macs = format_macs_from_interfaces(IFs),
    {ok, Macs}.

get_firmware_version()->
    os:cmd("cat /etc/lsb_release").  %% TODO - make platform agnostic

get_log_errors(Count)->
    %% TODO - allow log path to be overridden rather than force script to be run from miner dir
    %% TODO - finalise grep search terms
    POCErrors = os:cmd("grep -E \"error.*miner_poc|miner_poc.*error\" ./log/console.log | tail -n" ++ Count),
    TxnErrors = os:cmd("grep -E \"error.*blockchain_txn|blockchain_txn.*error\" ./log/console.log | tail -n" ++ Count),
    GenErrors = os:cmd("grep -E \"error\" | grep -Eiv \"blockchain_txn|miner_poc\" ./log/console.log | tail -n" ++ Count),
    {ok, [POCErrors], [TxnErrors], [GenErrors]}.

get_uptime()->
    {UpTimeMS, _} = statistics(wall_clock),
    UpTimeSec = (UpTimeMS div 1000) rem 1000000,
    DaysTime = calendar:seconds_to_daystime(UpTimeSec),
    format_days_time(DaysTime).

get_gateway_info(Chain, PubKey)->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKey, Ledger) of
        {error, _} ->
            "gateway not found in ledger";
        {ok, {GatewayAddr, Gateway}} ->
            lists:concat("gateway found in ledger, location: ", GatewayAddr:location(Gateway))
    end.

format_sync_height(SyncHeight, Height) when SyncHeight == Height ->
    integer_to_list(SyncHeight);
format_sync_height(SyncHeight, _Height) ->
    integer_to_list(SyncHeight) ++ "*".

format_days_time({Days, {H, M, S}}) when Days < 0 ->
    format_days_time({0, {H, M, S}});
format_days_time({Days, {H, M, S}})->
    lists:concat([Days, " Days, ",H, " Hours, ", M, " Minutes, ", S, " Seconds"]).

format_macs_from_interfaces(IFs)->
    lists:foldl(
        fun({IFName, Prop}, Acc) ->
            case proplists:get_value(hwaddr, Prop) of
                undefined -> Acc;
                HWAddr -> [IFName ++ " : " ++ format_hwaddr(HWAddr) ++ "\n" | Acc]
            end
        end,
    [], IFs).

format_hwaddr(HWAddr)->
    HWAddr0 = [integer_to_list(B,16) || B <- HWAddr ],
    lists:concat(HWAddr0).
