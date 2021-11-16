-module(miner_jsonrpc_info).

-include("miner_jsonrpc.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).
%% helpers
-export([get_gateway_location/3]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"info_height">>, []) ->
    Chain = blockchain_worker:blockchain(),
    {ok, SyncHeight} = blockchain:sync_height(Chain),
    {ok, #block_info_v2{height=Height, election_info={Epoch, _}}} = blockchain:head_block_info(Chain),
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
    #{name => ?BIN_TO_ANIMAL(blockchain_swarm:pubkey_bin())};
handle_rpc(<<"info_block_age">>, []) ->
    #{block_age => miner:block_age()};
handle_rpc(<<"info_p2p_status">>, []) ->
        #{
            "connected" := Connected,
            "dialable" := Dialable,
            "nat_type" := NatType,
            "height" := Height
        } = maps:from_list(miner:p2p_status()),
        #{
            connected => ?TO_VALUE(Connected),
            dialable => ?TO_VALUE(Dialable),
            nat_type => ?TO_VALUE(NatType),
            height => ?TO_VALUE(list_to_integer(Height))
        };
handle_rpc(<<"info_region">>, []) ->
    R =
        case miner_lora:region() of
            {ok, undefined} -> null;
            {ok, Region} -> atom_to_binary(Region, utf8)
        end,
    #{region => R};
handle_rpc(<<"info_location">>, []) ->
    PubKey = blockchain_swarm:pubkey_bin(),
    Chain = blockchain_worker:blockchain(),
    get_gateway_location(Chain, PubKey, #{});

%% TODO handle onboarding key data??
handle_rpc(<<"info_summary">>, []) ->
    PubKey = blockchain_swarm:pubkey_bin(),
    Chain = blockchain_worker:blockchain(),

    %% get gateway info
    MinerName = ?BIN_TO_ANIMAL(PubKey),
    Macs = get_mac_addrs(),
    BlockAge = miner:block_age(),
    Uptime = get_uptime(),
    FirmwareVersion = get_firmware_version(),
    GWInfo = get_gateway_info(Chain, PubKey),

    % get height data
    {ok, SyncHeight} = blockchain:sync_height(Chain),

    %% get epoch and height
    {ok, #block_info_v2{height=Height, election_info={Epoch, _}}} = blockchain:head_block_info(Chain),

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
        gateway_details => GWInfo,
        version => ?TO_VALUE(get_miner_version())
    };
handle_rpc(<<"info_version">>, []) ->
    #{version => ?TO_VALUE(get_miner_version())};
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%% internal

get_mac_addrs() ->
    {ok, IFs} = inet:getifaddrs(),
    Macs = format_macs_from_interfaces(IFs),
    Macs.

get_firmware_version() ->
    iolist_to_binary(os:cmd("cat /etc/lsb_release")).

get_miner_version() ->
    Releases = release_handler:which_releases(),
    case erlang:hd(Releases) of
        {_,ReleaseVersion,_,_} -> ReleaseVersion;
        {error,_} -> undefined
    end.

get_uptime() ->
    %% returns seconds of uptime
    {UpTimeMS, _} = statistics(wall_clock),
    (UpTimeMS div 1000) rem 1000000.

get_gateway_info(Chain, PubKey) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKey, Ledger) of
        {ok, Gateway} ->
            GWOwnAddr = libp2p_crypto:pubkey_bin_to_p2p(
                blockchain_ledger_gateway_v2:owner_address(Gateway)
            ),
            GWMode = blockchain_ledger_gateway_v2:mode(Gateway),
            get_gateway_location(Chain, Gateway, #{ 
                <<"owner">> => ?TO_VALUE(GWOwnAddr),
                <<"mode">> => ?TO_VALUE(GWMode)
            });
        _ ->
            undefined
    end.

get_gateway_location(Chain, PubKey, Dest) when is_binary(PubKey) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_gateway_info(PubKey, Ledger) of
        {ok, Gateway} -> get_gateway_location(Chain, Gateway, Dest);
        _ -> Dest
    end;
get_gateway_location(_Chain, Gateway, Dest) ->
    GWLoc = case blockchain_ledger_gateway_v2:location(Gateway) of
        undefined -> undefined;
        L -> h3:to_string(L)
    end,
    GWElevation = blockchain_ledger_gateway_v2:elevation(Gateway),
    GWGain = case blockchain_ledger_gateway_v2:gain(Gateway) of
        undefined -> undefined;
        V -> V / 10
    end,
    Dest#{ 
        <<"location">> => ?TO_VALUE(GWLoc),
        <<"gain">> => ?TO_VALUE(GWGain),
        <<"elevation">> => ?TO_VALUE(GWElevation)
     }.

format_macs_from_interfaces(IFs) ->
    lists:foldl(
        fun({IFName, Prop}, Acc) ->
            case proplists:get_value(hwaddr, Prop) of
                undefined -> Acc;
                HWAddr -> [ #{ ?TO_KEY(IFName) => ?TO_VALUE(format_hwaddr(HWAddr)) } | Acc]
            end
        end,
        [],
        IFs
    ).

format_hwaddr(HWAddr) ->
    string:to_upper(blockchain_utils:bin_to_hex(list_to_binary(HWAddr))).
