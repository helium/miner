%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion Server ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_server).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    decrypt_p2p/2,
    decrypt_radio/6,
    retry_decrypt/7,
    send_receipt/6,
    send_witness/4
]).

-ifdef(TEST).
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
    chain :: undefined  | blockchain:blockchain()
}).

-define(BLOCK_RETRY_COUNT, 10).
-define(CHANNELS, [903.9, 904.1, 904.3, 904.5, 904.7, 904.9, 905.1, 905.3]).
-define(TX_POWER, 27). %% 27 db

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

-spec decrypt_p2p(binary(), pid()) -> ok.
decrypt_p2p(Onion, Stream) ->
    gen_server:cast(?MODULE, {decrypt_p2p, Onion, Stream}).

decrypt_radio(Packet, RSSI, SNR, Timestamp, Freq, Spreading) ->
    gen_server:cast(?MODULE, {decrypt_radio, Packet, RSSI, SNR, Timestamp, Freq, Spreading}).

retry_decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream) ->
    gen_server:cast(?MODULE, {retry_decrypt, Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream}).

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid()) -> ok | {error, any()}.
send_receipt(_Data, OnionCompactKey, Type, Time, RSSI, Stream) ->
    case miner_lora:location_ok() of
        true ->
            <<ID:10/binary, _/binary>> = OnionCompactKey,
            lager:md([{poc_id, blockchain_utils:bin_to_hex(ID)}]),
            send_receipt(_Data, OnionCompactKey, Type, Time, RSSI, Stream, ?BLOCK_RETRY_COUNT);
        false ->
            ok
    end.

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid(), non_neg_integer()) -> ok | {error, any()}.
send_receipt(_Data, _OnionCompactKey, _Type, _Time, _RSSI, _Stream, 0) ->
    lager:error("failed to send receipts, max retry"),
    {error, too_many_retries};
send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Stream, Retry) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    {ok, PoCs} = blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger),
    Results = lists:foldl(
        fun(PoC, Acc) ->
            Challenger = blockchain_ledger_poc_v2:challenger(PoC),
            Address = blockchain_swarm:pubkey_bin(),
            Receipt0 = blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type),
            {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
            Receipt1 = blockchain_poc_receipt_v1:sign(Receipt0, SigFun),
            EncodedReceipt = blockchain_poc_response_v1:encode(Receipt1),
            case erlang:is_pid(Stream) of
                true ->
                    Stream ! {send, EncodedReceipt},
                    Acc;
                false ->
                    P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
                    case miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                        {error, _Reason} ->
                            lager:error("failed to dial challenger ~p (~p)", [P2P, _Reason]),
                            [error|Acc];
                        {ok, NewStream} ->
                            _ = miner_poc_handler:send(NewStream, EncodedReceipt),
                            Acc
                    end
            end
        end,
        [],
        PoCs
    ),
    case Results == [] of
        true ->
            ok;
        false ->
            timer:sleep(timer:seconds(30)),
            send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Stream, Retry-1)
    end.

-spec  send_witness(binary(), libp2p_crypto:pubkey_bin(), pos_integer(), integer()) -> ok.
send_witness(_Data, OnionCompactKey, Time, RSSI) ->
    case miner_lora:location_ok() of
        true ->
            <<ID:10/binary, _/binary>> = OnionCompactKey,
            lager:md([{poc_id, blockchain_utils:bin_to_hex(ID)}]),
            send_witness(_Data, OnionCompactKey, Time, RSSI, ?BLOCK_RETRY_COUNT);
        false ->
            ok
    end.

-spec send_witness(binary(), libp2p_crypto:pubkey_bin(), pos_integer(), integer(), non_neg_integer()) -> ok.
send_witness(_Data, _OnionCompactKey, _Time, _RSSI, 0) ->
    lager:error("failed to send witness, max retry");
send_witness(Data, OnionCompactKey, Time, RSSI, Retry) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    {ok, PoCs} = blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    lists:foreach(
        fun(PoC) ->
            Challenger = blockchain_ledger_poc_v2:challenger(PoC),
            Witness0 = blockchain_poc_witness_v1:new(SelfPubKeyBin, Time, RSSI, Data),
            {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
            Witness1 = blockchain_poc_witness_v1:sign(Witness0, SigFun),
            case SelfPubKeyBin =:= Challenger of
                true ->
                    lager:info("challenger is ourself so sending directly to poc statem"),
                    miner_poc_statem:witness(Witness1);
                false ->
                    EncodedWitness = blockchain_poc_response_v1:encode(Witness1),
                    P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
                    case miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                        {error, _Reason} ->
                            lager:warning("failed to dial challenger ~p: ~p", [P2P, _Reason]),
                            timer:sleep(timer:seconds(30)),
                            send_witness(Data, OnionCompactKey, Time, RSSI, Retry-1);
                        {ok, Stream} ->
                            _ = miner_poc_handler:send(Stream, EncodedWitness)
                    end
            end
        end,
        PoCs
    ),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("init with ~p", [Args]),
    {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())),
    MinerName = binary:replace(erlang:list_to_binary(Name), <<"-">>, <<" ">>, [global]),
    Chain = blockchain_worker:blockchain(),
    State = #state{
        compact_key = blockchain_swarm:pubkey_bin(),
        ecdh_fun = maps:get(ecdh_fun, Args),
        miner_name = unicode:characters_to_binary(MinerName, utf8),
        chain = Chain
    },
    {ok, State}.

handle_call(compact_key, _From, #state{compact_key=CK}=State) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(Msg, #state{chain = undefined} = State) ->
    %% we have no chain yet, so try and set it, the received packed will be dropped
    lager:warning("received ~p whilst no chain.  Dropping packet...", [Msg]),
    {noreply, State#state{chain = blockchain_worker:blockchain()}};

handle_cast({decrypt_p2p, <<IV:2/binary,
                            OnionCompactKey:33/binary,
                            Tag:4/binary,
                            CipherText/binary>>, Pid}, State) ->
    NewState = decrypt(p2p, IV, OnionCompactKey, Tag, CipherText, 0, Pid, State),
    {noreply, NewState};
handle_cast({decrypt_radio, <<IV:2/binary,
                              OnionCompactKey:33/binary,
                              Tag:4/binary,
                              CipherText/binary>>, RSSI, _SNR, _Timestamp, _Frequency, _Spreading}, State) ->
    NewState = decrypt(radio, IV, OnionCompactKey, Tag, CipherText, RSSI, undefined, State),
    {noreply, NewState};
handle_cast({retry_decrypt, Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream}, State) ->
    NewState = decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:warning("unhandled Msg: ~p", [_Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec wait_until_next_block() -> ok.
wait_until_next_block() ->
    receive
        {blockchain_event, {add_block, _BlockHash, _, _}} ->
            ok
    end.

-spec wait_for_block(function(), non_neg_integer()) -> ok | {error, any()}.
wait_for_block(Fun, Count) when Count > 0 ->
    ok = blockchain_event:add_handler(self()),
    wait_for_block_(Fun, Count).

-spec wait_for_block_(function(), non_neg_integer()) -> ok | {error, any()}.
wait_for_block_(_, 0) ->
    {error, no_matching_block_found};
wait_for_block_(Fun, Count) ->
    wait_until_next_block(),
    case Fun() of
        true ->
            ok;
        false ->
            wait_for_block_(Fun, Count - 1)
    end.

decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream, #state{ecdh_fun=ECDHFun, chain = Chain}=State) ->
    <<POCID:10/binary, _/binary>> = OnionCompactKey,
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    NewState = case try_decrypt(IV, OnionCompactKey, OnionKeyHash, Tag, CipherText, ECDHFun, Chain) of
        poc_not_found ->
            Ledger = blockchain:ledger(Chain),
            _ = erlang:spawn(fun() ->
                ok = wait_for_block(fun() ->
                    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
                        {ok, _} ->
                            true;
                        _ ->
                            false
                    end
                end, 10),
                ?MODULE:retry_decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream)
            end),
            State;
        {error, fail_decrypt} ->
            _ = erlang:spawn(
                ?MODULE,
                send_witness,
                [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>),
                 OnionCompactKey,
                 os:system_time(nanosecond), RSSI]
            ),
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "could not decrypt packet received via ~p: treating as a witness", [Type]),
            State;
        {ok, Data, NextPacket} ->
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "decrypted a layer: ~w received via ~p~n", [Data, Type]),
            %% fingerprint with a blank key
            Packet = longfi:serialize(<<0:128/integer-unsigned-little>>, longfi:new(monolithic, 0, 1, 0, NextPacket, #{})),
            %% deterministally pick a channel based on the layerdata
            <<IntData:16/integer-unsigned-little>> = Data,
            %% TODO calculate some kind of delay here
            case miner_lora:location_ok() of
                true ->
                    %% the fun below will be executed by miner_lora:send and supplied with the localised lists of channels
                    ChannelSelectorFun = fun(FreqList) -> lists:nth((IntData rem 8) + 1, FreqList) end,
                    erlang:spawn(fun() -> miner_lora:send_poc(Packet, immediate, ChannelSelectorFun, "SF10BW125", ?TX_POWER) end),
                    erlang:spawn(fun() -> ?MODULE:send_receipt(Data, OnionCompactKey, Type, os:system_time(nanosecond), RSSI, Stream)end);
                false ->
                    ok
            end,
            State;
        {error, Reason} ->
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "could not decrypt packet received via ~p: Reason, discarding", [Type, Reason]),
            State
    end,
    NewState.

-ifdef(EQC).
-spec try_decrypt(binary(), binary(), binary(), binary(), function()) -> {ok, binary(), binary()} | {error, any()}.
try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    case blockchain_worker:blockchain() of
        undefined->
            {error, chain_not_ready};
        Chain ->
            OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
            try_decrypt(IV, OnionCompactKey, OnionKeyHash, Tag, CipherText, ECDHFun, Chain)
    end.
-endif.

-spec try_decrypt(binary(), binary(), binary(), binary(), binary(), function(), blockchain:blockchain()) -> poc_not_found | {ok, binary(), binary()} | {error, any()}.
try_decrypt(IV, OnionCompactKey, OnionKeyHash, Tag, CipherText, ECDHFun, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
        {error, not_found} ->
            poc_not_found;
        {ok, [PoC]} ->
            Blockhash = blockchain_ledger_poc_v2:block_hash(PoC),
            try blockchain_poc_packet:decrypt(<<IV/binary, OnionCompactKey/binary, Tag/binary, CipherText/binary>>, ECDHFun, Blockhash, Ledger) of
                error ->
                    {error, fail_decrypt};
                {Payload, NextLayer} ->
                    {ok, Payload, NextLayer}
            catch _A:_B ->
                    {error, {_A, _B}}
            end;
        {ok, _} ->
            %% TODO we might want to try all the PoCs here
            {error, too_many_pocs}
    end.

