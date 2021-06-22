-module(miner_jsonrpc_info).

-include("miner_jsonrpc.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"info_height">>, []) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {Epoch, _} = blockchain_block_v1:election_info(HeadBlock),
    Output = #{
        epoch => Epoch,
        height => Height
    },
    case SyncHeight == Height of
        true -> Output;
        false -> Output#{sync_height => SyncHeight}
    end;
handle_rpc(<<"info_in_consensus">>, []) ->
    #{in_consensus => miner_consensus_mgr:in_consensus()};
handle_rpc(<<"info_name">>, []) ->
    #{name => iolist_to_binary(?TO_ANIMAL_NAME(blockchain_swarm:pubkey_bin()))};
handle_rpc(<<"info_block_age">>, []) ->
    #{block_age => miner:block_age()};
handle_rpc(<<"info_p2p_status">>, []) ->
    maps:from_list(miner:p2p_status());
handle_rpc(<<"info_region">>, []) ->
    R =
        case miner_lora:region() of
            {ok, undefined} -> <<"undefined">>;
            {ok, Region} -> atom_to_binary(Region, utf8)
        end,
    #{region => R};
%% TODO handle onboarding key data??
handle_rpc(<<"info_summary">>, []) ->
    PubKey = blockchain_swarm:pubkey_bin(),
    Chain = blockchain_worker:blockchain(),

    %% get gateway info
    MinerName = iolist_to_binary(?TO_ANIMAL_NAME(PubKey)),
    Macs = get_mac_addrs(),
    BlockAge = miner:block_age(),
    Uptime = get_uptime(),
    FirmwareVersion = get_firmware_version(),
    GWInfo = get_gateway_info(Chain, PubKey),

    % get height data
    {ok, Height} = blockchain:height(Chain),
    {ok, SyncHeight} = blockchain:sync_height(Chain),

    %% get epoch
    {ok, HeadBlock} = blockchain:head_block(Chain),
    {Epoch, _} = blockchain_block_v1:election_info(HeadBlock),

    %% get peerbook count
    Swarm = blockchain_swarm:swarm(),
    Peerbook = libp2p_swarm:peerbook(Swarm),
    PeerBookEntryCount = length(libp2p_peerbook:values(Peerbook)),

    #{
        name => MinerName,
        mac_addresses => Macs,
        block_age => BlockAge,
        epoch => Epoch,
        height => Height,
        sync_height => SyncHeight,
        uptime => Uptime,
        peer_book_entry_count => PeerBookEntryCount,
        firmware_version => FirmwareVersion,
        gateway_details => GWInfo
    };
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%% internal

get_mac_addrs() ->
    {ok, IFs} = inet:getifaddrs(),
    Macs = format_macs_from_interfaces(IFs),
    Macs.

get_firmware_version() ->
    iolist_to_binary(os:cmd("cat /etc/lsb_release")).

get_uptime() ->
    {UpTimeMS, _} = statistics(wall_clock),
    UpTimeSec = (UpTimeMS div 1000) rem 1000000,
    DaysTime = calendar:seconds_to_daystime(UpTimeSec),
    format_days_time(DaysTime).

get_gateway_info(Chain, PubKey) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKey, Ledger) of
        {ok, Gateway} ->
            GWLoc = blockchain_ledger_gateway_v2:location(Gateway),
            GWOwnAddr = libp2p_crypto:pubkey_bin_to_p2p(
                blockchain_ledger_gateway_v2:owner_address(Gateway)
            ),
            iolist_to_binary([
                lists:concat(["Gateway location: ", GWLoc]),
                lists:concat(["Owner address: ", GWOwnAddr])
            ]);
        _ ->
            "gateway not found in ledger"
    end.

format_days_time({Days, {H, M, S}}) when Days < 0 ->
    format_days_time({0, {H, M, S}});
format_days_time({Days, {H, M, S}}) ->
    iolist_to_binary(
        lists:concat([Days, " Days, ", H, " Hours, ", M, " Minutes, ", S, " Seconds"])
    ).

format_macs_from_interfaces(IFs) ->
    lists:foldl(
        fun({IFName, Prop}, Acc) ->
            case proplists:get_value(hwaddr, Prop) of
                undefined -> Acc;
                HWAddr -> [iolist_to_binary(IFName ++ " : " ++ format_hwaddr(HWAddr)) | Acc]
            end
        end,
        [],
        IFs
    ).

format_hwaddr(HWAddr) ->
    string:to_upper(blockchain_utils:bin_to_hex(list_to_binary(HWAddr))).
