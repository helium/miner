-module(miner_jsonrpc_ledger).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"ledger_balance">>, []) ->
    %% get all
    Entries = maps:filter(
        fun(K, _V) ->
            is_binary(K)
        end,
        blockchain_ledger_v1:entries(get_ledger())
    ),
    [format_ledger_balance(A, E) || {A, E} <- maps:to_list(Entries)];
handle_rpc(<<"ledger_balance">>, #{<<"address">> := Address}) ->
    %% get for address
    try
        BinAddr = ?B58_TO_BIN(Address),
        case blockchain_ledger_v1:find_entry(BinAddr, get_ledger()) of
            {error, not_found} -> ?jsonrpc_error({not_found, Address});
            {ok, Entry} -> format_ledger_balance(BinAddr, Entry)
        end
    catch
        _:_ -> ?jsonrpc_error({invalid_params, Address})
    end;
handle_rpc(<<"ledger_balance">>, #{<<"htlc">> := true}) ->
    %% get htlc
    H = maps:filter(
        fun(K, _V) -> is_binary(K) end,
        blockchain_ledger_v1:htlcs(get_ledger())
    ),
    maps:fold(
        fun(Addr, Htlc, Acc) ->
            [
                #{
                    <<"address">> => ?BIN_TO_B58(Addr),
                    <<"payer">> => ?BIN_TO_B58(blockchain_ledger_htlc_v1:payer(Htlc)),
                    <<"payee">> => ?BIN_TO_B58(blockchain_ledger_htlc_v1:payee(Htlc)),
                    <<"hashlock">> => blockchain_utils:bin_to_hex(
                        blockchain_ledger_htlc_v1:hashlock(Htlc)
                    ),
                    <<"timelock">> => blockchain_ledger_htlc_v1:timelock(Htlc),
                    <<"balance">> => blockchain_ledger_htlc_v1:balance(Htlc)
                }
                | Acc
            ]
        end,
        [],
        H
    );
handle_rpc(<<"ledger_balance">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"ledger_gateways">>, []) ->
    handle_rpc(<<"ledger_gateways">>, #{<<"verbose">> => false});
handle_rpc(<<"ledger_gateways">>, #{<<"verbose">> := Verbose}) ->
    L = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(L),
    blockchain_ledger_v1:cf_fold(
        active_gateways,
        fun({Addr, BinGw}, Acc) ->
            GW = blockchain_ledger_gateway_v2:deserialize(BinGw),
            [format_ledger_gateway_entry(Addr, GW, Height, Verbose) | Acc]
        end,
        [],
        L
    );
handle_rpc(<<"ledger_gateways">>, #{ <<"address">> := Address}) ->
    Ledger = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    try
        BinAddr = ?B58_TO_BIN(Address),
        case blockchain_ledger_v1:find_gateway_info(BinAddr, Ledger) of
            {error, not_found} -> ?jsonrpc_error({not_found, Address});
            {ok, GW} -> format_ledger_gateway_entry(BinAddr, GW, Height, true)
        end
    catch
        _:_ -> ?jsonrpc_error({invalid_params, Address})
    end;
handle_rpc(<<"ledger_gateways">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"ledger_validators">>, []) ->
    Ledger = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    blockchain_ledger_v1:cf_fold(
        validators,
        fun({Addr, BinVal}, Acc) ->
            Val = blockchain_ledger_validator_v1:deserialize(BinVal),
            [format_ledger_validator(Addr, Val, Ledger, Height) | Acc]
        end,
        [],
        Ledger
    );
handle_rpc(<<"ledger_validators">>, #{ <<"address">> := Address }) ->
    Ledger = get_ledger(),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    try
        BinAddr = ?B58_TO_BIN(Address),
        case blockchain_ledger_v1:get_validator(BinAddr, Ledger) of
            {error, not_found} -> ?jsonrpc_error({not_found, Address});
            {ok, Val} -> format_ledger_validator(BinAddr, Val, Ledger, Height)
        end
    catch
        _:_ -> ?jsonrpc_error({invalid_params, Address})
    end;
handle_rpc(<<"ledger_validators">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"ledger_variables">>, []) ->
    Vars = blockchain_ledger_v1:snapshot_vars(get_ledger()),
    lists:foldl(fun({K, V}, Acc) ->
                      BinK = ?TO_KEY(K),
                      BinV = ?TO_VALUE(V),
                      Acc#{ BinK => BinV }
              end, #{}, Vars);
handle_rpc(<<"ledger_variables">>, #{ <<"name">> := Name }) ->
    try
        NameAtom = binary_to_existing_atom(Name, utf8),
        case blockchain_ledger_v1:config(NameAtom, get_ledger()) of
            {ok, Var} ->
                #{ Name => ?TO_VALUE(Var) };
            {error, not_found} ->
                ?jsonrpc_error({not_found, Name})
        end
    catch
        error:badarg ->
            ?jsonrpc_error({invalid_params, Name})
    end;
handle_rpc(<<"ledger_variables">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"ledger_lora_region_parameters">>, #{ <<"region">> := Region}) ->
    Ledger = get_ledger(),
    try
        RegionAtom = binary_to_existing_atom(Region, utf8),
        case blockchain_region_params_v1:for_region(RegionAtom, Ledger) of
            {ok, RegionParams} ->
                format_region_parameters(RegionParams);
            {error, _Reason} ->
                ?jsonrpc_error({not_found, Region})
        end
    catch
        %% String-to-atom conversion will fail with this error if there is no
        %% atom present in the runtime for the given region. This is an
        %% implicit signal that there are no parameters for the region, and
        %% thus, the region likely doesn't exist.
        error:badarg ->
            ?jsonrpc_error({not_found, Region})
    end;
handle_rpc(<<"ledger_lora_region_parameters">>, []) ->
    ?jsonrpc_error({invalid_params, <<"region required">>});
handle_rpc(<<"ledger_lora_region_parameters">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

get_ledger() ->
    case blockchain_worker:blockchain() of
        undefined ->
            blockchain_ledger_v1:new("data");
        Chain ->
            blockchain:ledger(Chain)
    end.

format_ledger_balance(Addr, Entry) ->
    #{
        <<"address">> => ?BIN_TO_B58(Addr),
        <<"nonce">> => blockchain_ledger_entry_v1:nonce(Entry),
        <<"balance">> => blockchain_ledger_entry_v1:balance(Entry)
    }.

format_ledger_gateway_entry(Addr, GW, Height, Verbose) ->
    GWAddr = ?BIN_TO_B58(Addr),
    GWLoc = case blockchain_ledger_gateway_v2:location(GW) of
        undefined -> undefined;
        L -> h3:to_string(L)
    end,
    O = #{
        <<"name">> => iolist_to_binary(blockchain_utils:addr2name(Addr)),
        <<"address">> => GWAddr,
        <<"owner_address">> => ?BIN_TO_B58(blockchain_ledger_gateway_v2:owner_address(GW)),
        <<"location">> => ?TO_VALUE(GWLoc),
        <<"last_challenge">> => last_challenge(
            Height,
            blockchain_ledger_gateway_v2:last_poc_challenge(GW)
        ),
        <<"nonce">> => blockchain_ledger_gateway_v2:nonce(GW)
    },
    case Verbose of
        false ->
            O;
        true ->
            miner_jsonrpc_info:get_gateway_location(undefined, GW, O#{
                <<"mode">> => ?MAYBE(blockchain_ledger_gateway_v2:mode(GW))
            })
    end.

last_challenge(_Height, undefined) -> null;
last_challenge(Height, LC) -> Height - LC.

format_ledger_validator(Addr, Val, Ledger, Height) ->
    Penalties = blockchain_ledger_validator_v1:calculate_penalties(Val, Ledger),
    OwnerAddress = blockchain_ledger_validator_v1:owner_address(Val),
    LastHeartbeat = blockchain_ledger_validator_v1:last_heartbeat(Val),
    Stake = blockchain_ledger_validator_v1:stake(Val),
    Status = blockchain_ledger_validator_v1:status(Val),
    Version = blockchain_ledger_validator_v1:version(Val),
    Tenure = maps:get(tenure, Penalties, 0.0),
    DKG = maps:get(dkg, Penalties, 0.0),
    Perf = maps:get(performance, Penalties, 0.0),
    TotalPenalty = Tenure+Perf+DKG,
    #{
        <<"nonce">> => blockchain_ledger_validator_v1:nonce(Val),
        <<"name">> => ?BIN_TO_ANIMAL(Addr),
        <<"address">> => ?BIN_TO_B58(Addr),
        <<"owner_address">> => ?BIN_TO_B58(OwnerAddress),
        <<"last_heartbeat">> => Height - LastHeartbeat,
        <<"stake">> => Stake,
        <<"status">> => Status,
        <<"version">> => Version,
        <<"tenure_penalty">> => Tenure,
        <<"dkg_penalty">> => DKG,
        <<"performance_penalty">> => Perf,
        <<"total_penalty">> => TotalPenalty
    }.

-spec format_region_parameters([blockchain_region_param_v1:region_param_v1()]) ->
    [map()].
format_region_parameters(RegionParameters) ->
    [ format_region_parameter(RegionParameter) || RegionParameter <- RegionParameters ].

-spec format_region_parameter(blockchain_region_param_v1:region_param_v1()) ->
    map().
format_region_parameter(RegionParam) ->
    ChannelFrequencyHz = blockchain_region_param_v1:channel_frequency(RegionParam),
    BandwidthHz = blockchain_region_param_v1:bandwidth(RegionParam),
    MaxEIRPcBm = blockchain_region_param_v1:max_eirp(RegionParam),
    Spreading = blockchain_region_param_v1:spreading(RegionParam),
    SpreadingObject = format_spreading(Spreading),
    #{
        <<"channel_frequency_hz">> => ChannelFrequencyHz,
        <<"bandwidth_hz">> => BandwidthHz,
        <<"max_eirp_dbm">> => MaxEIRPcBm / 10.0,
        <<"spreading">> => SpreadingObject
    }.

-spec format_spreading(blockchain_region_spreading_v1:region_spreading_v1()) ->
    [map()].
format_spreading(Spreading) ->
    SpreadingList = blockchain_region_spreading_v1:tagged_spreading(Spreading),
    [ format_spreading_factor(SF) || SF <- SpreadingList ].

-spec format_spreading_factor(blockchain_region_spreading_v1:tagged_spreading()) ->
    map().
format_spreading_factor(SF) ->
    SFAtom = blockchain_region_spreading_v1:region_spreading(SF),
    MaxPacketSize = blockchain_region_spreading_v1:max_packet_size(SF),
    #{
        <<"factor">> => atom_to_binary(SFAtom, utf8),
        <<"max_packet_size">> => MaxPacketSize
    }.

