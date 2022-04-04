%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion Server for light gateways ==
%%          no use of chain or ledger
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_server_light).

-behavior(gen_server).

-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_caps.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    decrypt_p2p/1,
    decrypt_radio/7,
    retry_decrypt/11,
    send_receipt/11,
    send_witness/9,
    region_params_update/2,
    region_params/0
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(TX_RAND_SLEEP, 1).
-define(TX_MIN_SLEEP, 0).
-define(TX_COUNT, 1).
-else.
-define(TX_RAND_SLEEP, 10000).
-define(TX_MIN_SLEEP, 0).
-define(TX_COUNT, 3).
-endif.

-ifdef(EQC).
-export([try_decrypt/5]).
-endif.

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-record(state, {
    compact_key :: ecc_compact:compact_key(),
    ecdh_fun,
    miner_name :: binary(),
    sender :: undefined | {pid(), term()},
    packet_id = 0 :: non_neg_integer(),
    region_params = undefined :: undefined | blockchain_region_param_v1:region_param_v1(),
    region = undefined :: undefined | atom()
}).

-define(BLOCK_RETRY_COUNT, 10).
-define(CHANNELS, [903.9, 904.1, 904.3, 904.5, 904.7, 904.9, 905.1, 905.3]).

-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

-spec decrypt_p2p(binary()) -> ok.
decrypt_p2p(Onion) ->
    gen_server:cast(?MODULE, {decrypt_p2p, Onion}).

decrypt_radio(Packet, RSSI, SNR, Timestamp, Freq, Channel, Spreading) ->
    gen_server:cast(?MODULE, {decrypt_radio, Packet, RSSI, SNR, Timestamp, Freq, Channel, Spreading}).

retry_decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate, Stream) ->
    gen_server:cast(?MODULE, {retry_decrypt, Type, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate, Stream}).

-spec region_params_update(atom(), [blockchain_region_param_v1:region_param_v1()]) -> ok.
region_params_update(Region, RegionParams) ->
    gen_server:cast(?MODULE, {region_params_update, Region, RegionParams}).

-spec region_params() -> ok.
region_params() ->
    gen_server:call(?MODULE, region_params).

-spec send_receipt(Data :: binary(),
                   OnionCompactKey :: libp2p_crypto:pubkey_bin(),
                   Type :: radio | p2p,
                   Time :: pos_integer(),
                   RSSI :: integer(),
                   SNR :: float(),
                   Frequency :: float(),
                   Channel :: non_neg_integer(),
                   DataRate :: binary(),
                   Power :: non_neg_integer(),
                   State :: state()) -> ok | {error, any()}.
send_receipt(Data, OnionCompactKey, Type, Time, RSSI, SNR, Frequency, Channel, DataRate, Power, _State) ->
    case miner_lora_light:location_ok() of
        true ->
            lager:md([{poc_id, blockchain_utils:poc_id(OnionCompactKey)}]),
            OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
            Address = blockchain_swarm:pubkey_bin(),
            Receipt = case application:get_env(miner, data_aggregation_version, 3) of
                           1 ->
                               blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type, SNR, Frequency);
                           2 ->
                               blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type, SNR, Frequency, Channel, DataRate);
                           V when V >= 3 ->
                               R0 = blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type, SNR, Frequency, Channel, DataRate),
                               blockchain_poc_receipt_v1:tx_power(R0, Power);
                           _ ->
                               blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type)
                       end,

            %% TODO: put retry mechanism back in place
            miner_poc_grpc_client_statem:send_report(receipt, Receipt, OnionKeyHash);
        false ->
            ok
    end.

-spec send_witness(Data :: binary(),
                    OnionCompactKey :: libp2p_crypto:pubkey_bin(),
                    Time :: pos_integer(),
                    RSSI :: integer(),
                    SNR :: float(),
                    Frequency :: float(),
                    Channel :: non_neg_integer(),
                    DataRate :: binary(),
                    State :: state()) -> ok.
send_witness(Data, OnionCompactKey, Time, RSSI, SNR, Frequency, Channel, DataRate, _State) ->
    case miner_lora_light:location_ok() of
        true ->
            POCID = blockchain_utils:poc_id(OnionCompactKey),
            lager:debug([{poc_id, POCID}],
                       "sending witness at RSSI: ~p, Frequency: ~p, SNR: ~p",
                       [RSSI, Frequency, SNR]),
            OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
            SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
            Witness = case application:get_env(miner, data_aggregation_version, 2) of
                           V when V >= 2 ->
                               %% Send channel + datarate with data_aggregation_version >= 2
                               blockchain_poc_witness_v1:new(SelfPubKeyBin, Time, RSSI, Data, SNR, Frequency, Channel, DataRate);
                           1 ->
                               blockchain_poc_witness_v1:new(SelfPubKeyBin, Time, RSSI, Data, SNR, Frequency);
                           _ ->
                               blockchain_poc_witness_v1:new(SelfPubKeyBin, Time, RSSI, Data)
                       end,
            miner_poc_grpc_client_statem:send_report(witness, Witness, OnionKeyHash);
        false ->
            ok
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("init with ~p", [Args]),
    {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())),
    MinerName = binary:replace(erlang:list_to_binary(Name), <<"-">>, <<" ">>, [global]),
    State = #state{
        compact_key = blockchain_swarm:pubkey_bin(),
        ecdh_fun = maps:get(ecdh_fun, Args),
        miner_name = unicode:characters_to_binary(MinerName, utf8)
    },
    {ok, State}.

handle_call(region_params, _From, #state{region_params = Params}=State) ->
    {reply, {ok, Params}, State};
handle_call(compact_key, _From, #state{compact_key=CK}=State) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({region_params_update, Region, RegionParams}, State) ->
    lager:debug("updating region params. Region: ~p, Params: ~p", [Region, RegionParams]),
    {noreply, State#state{region = Region, region_params = RegionParams}};
handle_cast({decrypt_p2p, _Payload}, #state{region_params = undefined} = State) ->
    lager:warning("dropping p2p challenge packet as no region params data", []),
    {noreply, State};
handle_cast({decrypt_p2p, <<IV:2/binary,
                            OnionCompactKey:33/binary,
                            Tag:4/binary,
                            CipherText/binary>>}, State) ->
    %%TODO - rssi, freq, snr, channel and datarate were originally undefined
    %%       but this breaks the in use PB encoder, so defaulted to values below
    NewState = decrypt(p2p, IV, OnionCompactKey, Tag, CipherText, 0, 0.0, 0.0, 0, [12], State),
    {noreply, NewState};
handle_cast({decrypt_radio, _Payload}, #state{region_params = undefined} = State) ->
    lager:warning("dropping radio challenge packet as no region params data", []),
    {noreply, State};
handle_cast({decrypt_radio, <<IV:2/binary,
                              OnionCompactKey:33/binary,
                              Tag:4/binary,
                              CipherText/binary>>,
             RSSI, SNR, _Timestamp, Frequency, Channel, DataRate}, State) ->
    NewState = decrypt(radio, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate, State),
    {noreply, NewState};
handle_cast({retry_decrypt, Type, _IV, _OnionCompactKey, _Tag, _CipherText, _RSSI, _SNR, _Frequency, _Channel, _DataRate}, #state{region_params = undefined} = State) ->
    lager:warning("dropping retry ~p challenge packet as no region params data", [Type]),
    {noreply, State};
handle_cast({retry_decrypt, Type, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate}, State) ->
    NewState = decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("unhandled Msg: ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, SNR, Frequency, Channel, DataRate, #state{ecdh_fun=ECDHFun, region_params = RegionParams, region = Region}=State) ->
    POCID = blockchain_utils:poc_id(OnionCompactKey),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    lager:debug("attempting decrypt of type ~p for onion key hash ~p", [Type, OnionKeyHash]),
    NewState = case try_decrypt(IV, OnionCompactKey, OnionKeyHash, Tag, CipherText, ECDHFun) of
        {error, fail_decrypt} ->
            lager:info([{poc_id, POCID}],
                       "sending witness at RSSI: ~p, Frequency: ~p, SNR: ~p",
                       [RSSI, Frequency, SNR]),
            _ = erlang:spawn(
                ?MODULE,
                send_witness,
                [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>),
                 OnionCompactKey,
                 os:system_time(nanosecond), RSSI, SNR, Frequency, Channel, DataRate, State]
            ),
            lager:info([{poc_id, POCID}], "could not decrypt packet received via ~p: treating as a witness", [Type]),
            State;
        {ok, Data, NextPacket} ->
            lager:debug([{poc_id, POCID}], "decrypted a layer: ~w received via ~p~n", [Data, Type]),
            %% fingerprint with a blank key
            Packet = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(monolithic, 0, 1, 0, NextPacket, #{})),
            %% deterministally pick a channel based on the layerdata
            <<IntData:16/integer-unsigned-little>> = Data,
            %% TODO calculate some kind of delay here
            case miner_lora_light:location_ok() of
                true ->
                    %% the fun below will be executed by miner_lora:send and supplied with the localised lists of channels
                    ChannelSelectorFun = fun(FreqList) -> lists:nth((IntData rem length(FreqList)) + 1, FreqList) end,

                    %% NOTE: poc version used to be derived from ledger
                    %%       as we wont be following the chain, cant use that
                    case application:get_env(miner, poc_version, 11) of
                        POCVersion when POCVersion >= 11 ->
                            %% send receipt with poc_v11 updates
                            case RegionParams of
                                undefined ->
                                    %% continue doing the old way
                                    %% the fun below will be executed by miner_lora:send and supplied with the localised lists of channels
                                    Spreading = spreading(Region, erlang:byte_size(Packet)),
                                    TxPower = tx_power(Region),
                                    erlang:spawn(fun() -> miner_lora_light:send_poc(Packet, immediate, ChannelSelectorFun, Spreading, TxPower) end),
                                    erlang:spawn(fun() -> ?MODULE:send_receipt(Data, OnionCompactKey, Type, os:system_time(nanosecond),
                                                                               RSSI, SNR, Frequency, Channel, DataRate, TxPower, State) end);
                                _ ->
                                    case blockchain_region_params_v1:get_spreading(RegionParams, erlang:byte_size(Packet)) of
                                        {error, Why} ->
                                            lager:error("unable to get spreading, reason: ~p", [Why]),
                                            ok;
                                        {ok, Spreading} ->
                                            case tx_power(Region, State) of
                                                {error, Reason} ->
                                                    %% could not calculate txpower, don't do anything
                                                    lager:error("unable to get tx_power, reason: ~p", [Reason]),
                                                    ok;
                                                {ok, TxPower, EffectiveTxPower, AssertedGain} ->
                                                    %% TxPower is the power we tell the radio to transmit at
                                                    %% and EffectiveTxPower is the power we expect to radiate at the
                                                    %% antenna.
                                                    BW = blockchain_region_params_v1:get_bandwidth(RegionParams),
                                                    DR = datarate(Spreading, BW),
                                                    case miner_lora_light:send_poc(Packet, immediate, ChannelSelectorFun, DR, TxPower) of
                                                        ok ->
                                                            lager:info("sending receipt with observed power: ~p with radio power ~p", [EffectiveTxPower, TxPower]),
                                                            ?MODULE:send_receipt(Data, OnionCompactKey, Type, os:system_time(nanosecond),
                                                                                 RSSI, SNR, Frequency, Channel, DataRate, EffectiveTxPower, State);
                                                        {warning, {tx_power_corrected, CorrectedPower}} ->
                                                            %% Corrected power never takes into account antenna gain config in pkt forwarder so we
                                                            %% always add it back here
                                                            lager:warning("tx_power_corrected! original_power: ~p, corrected_power: ~p, with gain ~p; sending receipt with power ~p",
                                                                          [TxPower, CorrectedPower, AssertedGain, CorrectedPower + AssertedGain]),
                                                            ?MODULE:send_receipt(Data, OnionCompactKey, Type, os:system_time(nanosecond),
                                                                                 RSSI, SNR, Frequency, Channel, DataRate, CorrectedPower + AssertedGain, State);
                                                        {warning, {unknown, Other}} ->
                                                            %% This should not happen
                                                            lager:warning("What is this? ~p", [Other]),
                                                            ok;
                                                        {error, Reason} ->
                                                            lager:error("unable to send_poc, reason: ~p", [Reason]),
                                                            ok
                                                    end
                                            end
                                    end
                                end
                    end;
                false ->
                    ok
            end,
            State;
        {error, Reason} ->
            lager:info([{poc_id, POCID}], "could not decrypt packet received via ~p: Reason, discarding", [Type, Reason]),
            State
    end,
    NewState.

-spec try_decrypt(binary(), binary(), binary(), binary(), binary(), function()) -> poc_not_found | {ok, binary(), binary()} | {error, any()}.
try_decrypt(IV, OnionCompactKey, _OnionKeyHash, Tag, CipherText, ECDHFun) ->
            try blockchain_poc_packet_v2:decrypt(<<IV/binary, OnionCompactKey/binary, Tag/binary, CipherText/binary>>, ECDHFun) of
                error ->
                    {error, fail_decrypt};
                {Payload, NextLayer} ->
                    {ok, Payload, NextLayer}
            catch _A:_B:_C ->
                lager:error("A: ~p, B: ~p, C: ~p", [_A, _B, _C]),
                    {error, {_A, _B}}
            end.
%%    end.

-spec tx_power(Region :: atom(), State :: state()) -> {ok, pos_integer(), pos_integer(), non_neg_integer()} | {error, any()}.
tx_power(Region, #state{compact_key=_CK, region_params = RegionParams}) ->
    try
        MaxEIRP = lists:max([blockchain_region_param_v1:max_eirp(R) || R <- RegionParams]),
        %% if the antenna gain is accounted for in the packet forwarder config file
        %% set this to false
        %% ConsiderTxGain = application:get_env(miner, consider_tx_gain, true),
        %% TODO - revisit as we are dropping the GW gain from the ledger
        %%        do we need an API to pull this from a validator ?
        EIRP = trunc(MaxEIRP/10),
        lager:info("Region: ~p, Gain: ~p, MaxEIRP: ~p, EIRP: ~p",
                   [Region, undefined, MaxEIRP/10, EIRP]),
        {ok, EIRP, EIRP, 0}
    catch _Class:_Error ->
        {error, failed_to_get_tx_power}
    end.

-spec datarate(Spreading :: atom(), BW :: pos_integer()) -> string().
datarate(Spreading, BW) ->
    BWInKhz = trunc(BW / 1000),
    atom_to_list(Spreading) ++ "BW" ++ integer_to_list(BWInKhz).

-spec tx_power(atom()) -> pos_integer().
tx_power('EU868') ->
    14;
tx_power('US915') ->
    27;
tx_power(_) ->
    27.

-spec spreading(Region :: atom(),
                Len :: pos_integer()) -> string().
spreading('EU868', L) when L < 65 ->
    "SF12BW125";
spreading('EU868', L) when L < 129 ->
    "SF9BW125";
spreading('EU868', L) when L < 238 ->
    "SF8BW125";
spreading(_, L) when L < 25 ->
    "SF10BW125";
spreading(_, L) when L < 67 ->
    "SF9BW125";
spreading(_, L) when L < 139 ->
    "SF8BW125";
spreading(_, _) ->
    "SF7BW125".

-ifdef(EQC).
-spec try_decrypt(binary(), binary(), binary(), binary(), function()) -> {ok, binary(), binary()} | {error, any()}.
try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    try_decrypt(IV, OnionCompactKey, OnionKeyHash, Tag, CipherText, ECDHFun).
-endif.
