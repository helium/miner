%%%-------------------------------------------------------------------
%% @doc miner_cli_info
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_info).

-behavior(clique_handler).


-export([register_cli/0]).

-export([get_info/0]).

-include_lib("blockchain/include/blockchain.hrl").


-define(DEFAULT_LOG_HIT_COUNT, "5").                                                        %% the default number of error log hits to return as part of info summary
-define(DEFAULT_LOG_SCAN_RANGE, "500").                                                     %% the default number of error log entries to scan as part of info summary
-define(ONBOARDING_API_URL_BASE, "https://onboarding.dewi.org/api/v2").

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
                   info_onboarding_usage(),
                   info_summary_usage(),
                   info_region_usage()
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
                   info_onboarding_cmd(),
                   info_summary_cmd(),
                   info_region_cmd()
                  ]).
%%
%% info
%%

info_usage() ->
    [["info"],
     ["miner info commands\n\n",
      "  info height            - Get height of the blockchain for this miner.\n",
      "  info in_consensus      - Show if this miner is in the consensus_group.\n"
      "  info name              - Shows the name of this miner.\n"
      "  info block_age         - Get age of the latest block in the chain, in seconds.\n"
      "  info p2p_status        - Shows key peer connectivity status of this miner.\n"
      "  info onboarding        - Get manufacturing and staking details for this miner.\n"
      "  info summary           - Get a collection of key data points for this miner.\n"
      "  info region            - Get the operatating region for this miner.\n"
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
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, #block_info_v2{election_info={Epoch, _}, height=Height}} = blockchain:head_block_info(Chain),
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
      "  Get whether this miner is currently in the consensus group.\n\n"
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
      "  Get animal name for this miner.\n\n"
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
    [clique_status:table(lists:map(fun tuple_to_table_row/1, StatusResults))];

info_p2p_status([_, _, _], [], []) ->
    usage.

%%
%% info region
%%

info_region_cmd() ->
    [
     [["info", "region"], [], [], fun info_region/3]
    ].

info_region_usage() ->
    [["info", "region"],
     ["info region \n\n",
      "  Get the frequency region this miner is operating in \n\n"
      "  If undefined, the region has not yet been confirmed or cannot be determined\n"
      "  Until a region is confirmed, the miner will block tx\n"
     ]
    ].

info_region(["info", "region"], [], []) ->
    case miner_lora:region() of
        {ok, undefined} ->
            {exit_status, 1, [clique_status:text("undefined")]};
        {ok, Region} ->
             [clique_status:text(atom_to_list(Region))]
    end;
info_region([_, _, _], [], []) ->
    usage.

%%
%% info onboarding
%%

info_onboarding_usage() ->
    [["info", "onboarding"],
     ["info onboarding [-k <key>] [-p]\n\n",
      "  Get the manufacturing information for this miner, querying the\n"
      "  Decentralized Wireless Alliance server.\n"
      "\n"
      "  Options\n"
      "\n"
      "    -k, --key <onboarding-key>\n"
      "        Use the specified onboarding key rather than the key for this miner.\n"
      "    -p, --payer\n"
      "        After obtaining the information, just print the manufacturer's payer key\n"
      "        This is the key that should be named when requesting signatures for\n"
      "        transactions that require manufacturer staking.\n"
     ]
    ].

info_onboarding_cmd() ->
    [
     [["info", "onboarding"], [],
        [
            {just_payer, [ {shortname, "p"}, {longname, "payer"}]},
            {key, [ {shortname, "k"}, {longname, "key"}, {datatype, string}]}
        ], fun info_onboarding/3]
    ].

info_onboarding(["info", "onboarding"], [], Flags) ->
    OnboardingKey = case proplists:get_value(key, Flags, undefined) of
        undefined ->
            #{ onboarding_key := MinerOnboardingKey } = miner_keys:keys(),
            MinerOnboardingKey;
        ProvidedKey ->
            ProvidedKey
    end,
    PayerOutputOnly = proplists:is_defined(just_payer, Flags),
    
    case OnboardingKey of
        undefined ->
            error_message("This miner has no onboarding key, no onboarding info available.");
        OK ->
            case onboarding_info_for_key(OK) of
                {ok, OnboardingInfo} ->
                    clique_status_for_onboarding_info(OnboardingInfo, PayerOutputOnly);
                notfound ->
                    error_message("No onboarding info found for this miner's onboarding key.");
                {error, Code} ->
                    error_message(io_lib:format("Onboarding server unexcpetedly returned code ~p.", [ Code ]))
            end
    end.

%%
%% Onboarding information is generally divided into two parts: information
%% specific to this miner ("MinerData") and information about its manufacturer
%% ("MakerData").
%%
-spec onboarding_info_for_key(string()) -> {ok, {map(), map()}} | notfound | {error, non_neg_integer()}.
onboarding_info_for_key(OnboardingKey) ->
    Url = ?ONBOARDING_API_URL_BASE ++ "/hotspots/" ++ OnboardingKey, 
    case get_api_json_as_map(Url) of
        {ok, OnboardingResult} ->
            OnboardingData = maps:get(<<"data">>, OnboardingResult),
            MakerData      = maps:get(<<"maker">>, OnboardingData),
            IsMinerData = fun (Key, _Value) -> Key =/= <<"maker">> end,
            MinerData = maps:filter(IsMinerData, OnboardingData),
            {ok, {MinerData, MakerData}};
        notfound -> notfound;
        {error, Code} -> {error, Code}
    end.

-spec clique_status_for_onboarding_info({map(), map()}, boolean()) -> list().
clique_status_for_onboarding_info({MinerData, MakerData}, PayerOutputOnly) ->
    case PayerOutputOnly of
        true -> 
            PayerAddress = maps:get(<<"address">>, MakerData),
            PayerAddressString = binary_to_list(PayerAddress),
            [ clique_status:text(PayerAddressString) ];
        false -> full_status_for_onboarding_info(MinerData, MakerData)
    end.

-spec full_status_for_onboarding_info(map(), map()) -> list().
full_status_for_onboarding_info(MinerData, MakerData) ->
    MinerDisplay = maps:to_list(MinerData),
    MakerDisplay = maps:to_list(MakerData),
    [
        clique_status:text("\n********************\nGeneral Manufacturing Info\n********************\n"),
        clique_status:table(lists:map(fun tuple_to_table_row/1, MinerDisplay)),
        clique_status:text("\n********************\nManufacturer Info\n********************\n"),
        clique_status:table(lists:map(fun tuple_to_table_row/1, MakerDisplay))
    ].

%%
%% info summary
%%

info_summary_cmd() ->
    [
     [["info", "summary"], [],
      [{error_count, [  {shortname, "e"},
                        {longname, "error_count"}]},
       {scan_range, [   {shortname, "s"},
                        {longname, "scan_range"}]}
      ], fun info_summary/3]
    ].

info_summary_usage() ->
    [["info", "summary"],
     ["info summary \n\n",
      "  Get a collection of key data points for this miner.\n\n"
      "  Also returns the last " ++ ?DEFAULT_LOG_HIT_COUNT ++ " error log entries across 3 categories: Transactions, POCs and Other errors.\n"
      "  By default the latest " ++ ?DEFAULT_LOG_SCAN_RANGE ++ " log entries are scanned and the most recent " ++ ?DEFAULT_LOG_HIT_COUNT ++ " hits for each category returned\n\n"
      "Options\n\n"
      "  -e, --error_count <count> "
      "    Set the count of log entries to return per category)\n"
      "  -s, --scan_range <range> "
      "    Set the maximum number of log entries to scan\n\n"

     ]
    ].

get_summary_info(ErrorCount, ScanRange)->
    PubKey = blockchain_swarm:pubkey_bin(),
    Chain = blockchain_worker:blockchain(),

    %% get gateway info
    {ok, MinerName} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(PubKey)),
    Macs = get_mac_addrs(),
    BlockAge = miner:block_age(),
    Uptime = get_uptime(),
    FirmwareVersion = get_firmware_version(),
    GWInfo = get_gateway_info(Chain, PubKey),

    % get height data
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    SyncHeight0 = format_sync_height(SyncHeight, Height),

    %% get epoch
    {ok, #block_info_v2{election_info={Epoch, _}}} = blockchain:head_block_info(Chain),

    %% get peerbook count
    Swarm = blockchain_swarm:swarm(),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    PeerBookEntryCount = length(libp2p_peerbook:values(Peerbook)),

    %% get recent error log entries
    {POCErrors, TxnErrors, GenErrors} = get_log_errors(ErrorCount, ScanRange),

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

info_summary(["info", "summary"], _Keys, Flags) ->
    ErrorCount = proplists:get_value(error_count, Flags, ?DEFAULT_LOG_HIT_COUNT),
    ScanRange = proplists:get_value(scan_range, Flags, ?DEFAULT_LOG_SCAN_RANGE),
    do_info_summary(ErrorCount, ScanRange).

do_info_summary(ErrorCount, ScanRange) ->
    {GeneralInfo, POCErrorInfo,
        TxnErrorInfo, GenErrorInfo} = get_summary_info(ErrorCount, ScanRange),

    [   clique_status:text("\n********************\nMiner General Info\n********************\n"),
        clique_status:table(lists:map(fun tuple_to_table_row/1, GeneralInfo)),
        clique_status:text("\n********************\nMiner P2P Info\n********************\n"),
        hd(info_p2p_status(["info", "p2p_status"], [], [])),
        clique_status:text("\n********************\nMiner log errors\n********************\n"),
        clique_status:list(  "***** Transaction related errors *****\n\n", TxnErrorInfo),
        clique_status:list(  "***** POC related errors         *****\n\n", POCErrorInfo),
        clique_status:list(  "***** General errors             *****\n\n", GenErrorInfo)

    ].

%%
%% Utility functions.
%%
get_mac_addrs()->
    {ok, IFs} = inet:getifaddrs(),
    Macs = format_macs_from_interfaces(IFs),
    Macs.

get_firmware_version()->
    os:cmd("cat /etc/lsb_release").

get_log_errors(ErrorCount, ScanRange)->
    {ok, BaseDir} = application:get_env(lager, log_root),
    LogPath = lists:concat([BaseDir, "/console.log"]),

    TxnErrors = os:cmd(          "tail -n" ++ ScanRange ++ " " ++ LogPath ++ " | sort -rn |"
                                 "grep -m" ++ ErrorCount ++ " -E \"error.*blockchain_txn|blockchain_txn.*error\""
                                 ),

    POCErrors = os:cmd(          "tail -n" ++ ScanRange ++ " " ++ LogPath ++ " | sort -rn |"
                                 "grep -m" ++ ErrorCount ++ " -E \"error.*miner_poc|miner_poc.*error|error.*blockchain_poc|blockchain_poc.*error\""
                                 ),

    GenErrors = os:cmd(          "tail -n" ++ ScanRange  ++ " " ++ LogPath ++ " | sort -rn |"
                                 "grep -m" ++ ErrorCount ++ " -E \"error\" | "
                                 "grep -Ev \"blockchain_txn|miner_poc|blockchain_poc|absorbing\""
                                 ),

    {[POCErrors], [TxnErrors], [GenErrors]}.

get_uptime()->
    {UpTimeMS, _} = statistics(wall_clock),
    UpTimeSec = (UpTimeMS div 1000) rem 1000000,
    DaysTime = calendar:seconds_to_daystime(UpTimeSec),
    format_days_time(DaysTime).

get_gateway_info(Chain, PubKey)->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKey, Ledger) of
        {ok, Gateway} ->
            GWLoc = blockchain_ledger_gateway_v2:location(Gateway),
            GWOwnAddr = libp2p_crypto:pubkey_bin_to_p2p(blockchain_ledger_gateway_v2:owner_address(Gateway)),
            [lists:concat(["Gateway location: ", GWLoc]), lists:concat(["Owner address: ", GWOwnAddr])];
        _ ->
            "gateway not found in ledger"
    end.

%%
%% Query an HTTP/HTTPS endpoint, interpreting the body as JSON, and thence,
%% returning it as a map.
%%
-spec get_api_json_as_map(string()) -> {ok, map()} | notfound | {error, non_neg_integer()}.
get_api_json_as_map(Url) ->
    {ok, Result} = httpc:request(get, {Url,[{"connection", "close"}]}, [], [{body_format, binary}]),
    {HTTPMessage, _Headers, Data} = Result,
    {_HTTPVersion, ReturnCode, _ResponseMessage} = HTTPMessage,
    if
        ReturnCode >= 200 andalso ReturnCode =< 299 -> {ok, jsx:decode(Data, [return_maps])};
        ReturnCode == 404 -> notfound;
        true -> {error, ReturnCode}
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
   string:to_upper(blockchain_utils:bin_to_hex(list_to_binary(HWAddr))).

tuple_to_table_row({Name, Result}) ->
    [{name, Name}, {result, Result}].

-spec error_message(string()) -> list().
error_message(Text) ->
    [ clique_status:alert([clique_status:text("Error: " ++ Text)]) ].
