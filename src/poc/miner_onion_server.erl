%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion Server ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_server).

-behavior(gen_server).

-include_lib("helium_proto/src/pb/helium_longfi_pb.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    send/1,
    decrypt/2,
    send_receipt/6,
    send_witness/4,
    send_to_router/2
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

-define(READ_RADIO_PACKET_EXTENDED, 16#82).

-define(BLOCK_RETRY_COUNT, 10).

-record(state, {
    udp_socket :: gen_udp:socket(),
    udp_send_port :: pos_integer(),
    udp_send_ip :: inet:address(),
    compact_key :: ecc_compact:compact_key(),
    ecdh_fun,
    miner_name :: binary(),
    sender :: undefined | {pid(), term()},
    packet_id = 0 :: non_neg_integer(),
    pending_transmits = [] ::  [{non_neg_integer(), reference()}],
    ciphertexts = [] :: [binary()]
}).

-define(CHANNELS, [916.2e6, 916.4e6, 916.6e6, 916.8e6, 917.0e6, 920.2e6, 920.4e6, 920.6e6]).
-define(TX_POWER, 28). %% 28 db

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

-spec send(binary()) -> ok.
send(Data) ->
    gen_server:call(?MODULE, {send, Data}).

-spec decrypt(binary(), pid()) -> ok.
decrypt(Onion, Stream) ->
    gen_server:cast(?MODULE, {decrypt, Onion, Stream}).

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid()) -> ok | {error, any()}.
send_receipt(_Data, OnionCompactKey, Type, Time, RSSI, Stream) ->
    ok = blockchain_event:add_handler(self()),
    <<ID:10/binary, _/binary>> = OnionCompactKey,
    lager:md([{poc_id, blockchain_utils:bin_to_hex(ID)}]),
    send_receipt(_Data, OnionCompactKey, Type, Time, RSSI, Stream, ?BLOCK_RETRY_COUNT).

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid(), non_neg_integer()) -> ok | {error, any()}.
send_receipt(_Data, _OnionCompactKey, _Type, _Time, _RSSI, _Stream, 0) ->
    lager:error("failed to send receipts, max retry"),
    {error, too_many_retries};
send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Stream, Retry) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
        {error, _Reason} ->
            lager:warning("no gateway found with onion ~p (~p)", [OnionCompactKey, _Reason]),
            ok = wait_until_next_block(),
            send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Stream, Retry-1);
        {ok, PoCs} ->
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
                    ok = wait_until_next_block(),
                    send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Stream, Retry-1)
            end
    end,
    ok.

-spec  send_witness(binary(), libp2p_crypto:pubkey_bin(), pos_integer(), integer()) -> ok.
send_witness(_Data, OnionCompactKey, Time, RSSI) ->
    ok = blockchain_event:add_handler(self()),
    <<ID:10/binary, _/binary>> = OnionCompactKey,
    lager:md([{poc_id, blockchain_utils:bin_to_hex(ID)}]),
    send_witness(_Data, OnionCompactKey, Time, RSSI, ?BLOCK_RETRY_COUNT).

-spec send_witness(binary(), libp2p_crypto:pubkey_bin(), pos_integer(), integer(), non_neg_integer()) -> ok.
send_witness(_Data, _OnionCompactKey, _Time, _RSSI, 0) ->
    lager:error("failed to send witness, max retry");
send_witness(Data, OnionCompactKey, Time, RSSI, Retry) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
        {error, _Reason} ->
            lager:warning("no gateway found with onion ~p (~p)", [OnionCompactKey, _Reason]),
            ok = wait_until_next_block(),
            send_witness(Data, OnionCompactKey, Time, RSSI, Retry-1);
        {ok, PoCs} ->
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
                                    ok = wait_until_next_block(),
                                    send_witness(Data, OnionCompactKey, Time, RSSI, Retry-1);
                                {ok, Stream} ->
                                    _ = miner_poc_handler:send(Stream, EncodedWitness)
                            end
                    end
                end,
                PoCs
            )
    end,
    ok.

-spec send_to_router(binary(), any()) -> ok.
send_to_router(Name, #helium_LongFiResp_pb{kind={rx, #helium_LongFiRxPacket_pb{oui=OUI}}}=Resp) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("ingnored packet chain is undefined");
        Chain ->
            Ledger = blockchain:ledger(Chain),
            Swarm = blockchain_swarm:swarm(),
            Packet = helium_longfi_pb:encode_msg(Resp#helium_LongFiResp_pb{miner_name=Name}),
            case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                {error, _Reason} ->
                    case application:get_env(miner, default_router, undefined) of
                        undefined ->
                            lager:warning("ingnored could not find OUI ~p in ledger and no default router is set", [OUI]);
                        Address ->
                            send_to_router(Swarm, Address, Packet)
                    end;
                {ok, Routing} ->
                    Addresses = blockchain_ledger_routing_v1:addresses(Routing),
                    lager:debug("found addresses ~p", [Addresses]),
                    lists:foreach(
                        fun(BinAddress) ->
                            Address = erlang:binary_to_list(BinAddress),
                            send_to_router(Swarm, Address, Packet)
                        end,
                        Addresses
                    )
            end
    end.

send_to_router(Swarm, Address, Packet) ->
    RegName = erlang:list_to_atom(Address),
    case erlang:whereis(RegName) of
        Stream when is_pid(Stream) ->
            Stream ! {send, Packet},
            lager:info("sent packet ~p to ~p", [Packet, Address]);
        undefined ->
            Result = libp2p_swarm:dial_framed_stream(Swarm,
                                                     Address,
                                                     router_handler:version(),
                                                     router_handler,
                                                     []),
            case Result of
                {ok, Stream} ->
                    Stream ! {send, Packet},
                    catch erlang:register(RegName, Stream),
                    lager:info("sent packet ~p to ~p", [Packet, Address]);
                {error, _Reason} ->
                    lager:error("failed to send packet ~p to ~p (~p)", [Packet, Address, _Reason])
            end
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    UDPPort = maps:get(radio_udp_bind_port, Args),
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPSendPort = maps:get(radio_udp_send_port, Args),
    UDPSendIP = maps:get(radio_udp_send_ip, Args),
    {ok, UDP} = gen_udp:open(UDPPort, [{ip, UDPIP}, {port, UDPPort}, binary, {active, once}, {reuseaddr, true}]),
    {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())),
    MinerName = binary:replace(erlang:list_to_binary(Name), <<"-">>, <<" ">>, [global]),
    State = #state{
        compact_key = blockchain_swarm:pubkey_bin(),
        udp_socket = UDP,
        udp_send_port = UDPSendPort,
        udp_send_ip = UDPSendIP,
        ecdh_fun = maps:get(ecdh_fun, Args),
        miner_name = unicode:characters_to_binary(MinerName, utf8)
    },
    lager:info("init with ~p", [Args]),
    {ok, State}.

handle_call(compact_key, _From, #state{compact_key=CK}=State) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call({send, Data}, _From, #state{udp_socket=Socket, udp_send_ip=IP, udp_send_port=Port,
                                        packet_id=ID, pending_transmits=Pendings }=State) ->
    Fragmentation = application:get_env(miner, poc_fragmentation, true),
    {Spreading, _CodeRate} = tx_params(erlang:byte_size(Data), Fragmentation),
    Ref = erlang:send_after(15000, self(), {tx_timeout, ID}),
    UpLink = #helium_LongFiTxPacket_pb{
                oui = 0,
                device_id = 1,
                spreading=Spreading,
                payload=Data
               },
    Req = #helium_LongFiReq_pb{id=ID, kind={tx_uplink, UpLink}},
    lager:info("sending ~p", [Req]),
    Packet = helium_longfi_pb:encode_msg(Req),
    spawn(fun() ->
                  %% sleep from 3-13 seconds before sending
                  timer:sleep(rand:uniform(?TX_RAND_SLEEP) + ?TX_MIN_SLEEP),
                  gen_udp:send(Socket, IP, Port, Packet)
          end),
    {reply, ok, State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|Pendings]}};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({decrypt, <<IV:2/binary,
                        OnionCompactKey:33/binary,
                        Tag:4/binary,
                        CipherText/binary>>, Pid}, State) ->
    NewState = decrypt(p2p, IV, OnionCompactKey, Tag, CipherText, 0, Pid, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Packet}, State = #state{udp_send_ip=IP, udp_send_port=Port}) ->
    lager:debug("got packet ~p", [Packet]),
    NewState =
        try helium_longfi_pb:decode_msg(Packet, helium_LongFiResp_pb) of
            Resp ->
                lager:debug("decoded packet ~p", [Resp]),
                handle_packet(Resp, State)
        catch
            What:Why ->
                lager:warning("Failed to handle radio packet ~p -- ~p:~p", [Packet, What, Why]),
                State
        end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, NewState};
handle_info({tx_timeout, ID}, State=#state{pending_transmits=Pending}) ->
    lager:warning("TX timeout for ~p", [ID]),
    {noreply, State#state{pending_transmits=lists:keydelete(ID, 1, Pending)}};
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

decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream, #state{ecdh_fun=ECDHFun,
                                                                         udp_socket=Socket,
                                                                         udp_send_ip=IP,
                                                                         udp_send_port=Port,
                                                                         packet_id=ID}=State) ->
    <<POCID:10/binary, _/binary>> = OnionCompactKey,
    NewState = case try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
        {error, _Reason} ->
            _ = erlang:spawn(
                ?MODULE,
                send_witness,
                [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>),
                 OnionCompactKey,
                 os:system_time(nanosecond), RSSI]
            ),
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "could not decrypt packet received via ~p: ~p", [Type, _Reason]),
            State;
        {ok, Data, NextPacket} ->
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "decrypted a layer: ~w received via ~p~n", [Data, Type]),
            Ref = erlang:send_after(15000, self(), {tx_timeout, ID}),
            Fragmentation = application:get_env(miner, poc_fragmentation, true),
            {Spreading, _CodeRate} = tx_params(erlang:byte_size(Data), Fragmentation),
            UpLink = #helium_LongFiTxPacket_pb{
                oui=0,
                device_id=1,
                spreading=Spreading,
                payload=NextPacket
            },
            Req = #helium_LongFiReq_pb{id=ID, kind={tx_uplink, UpLink}},
            lager:info([{poc_id, blockchain_utils:bin_to_hex(POCID)}], "sending ~p", [Req]),
            Packet = helium_longfi_pb:encode_msg(Req),
            erlang:spawn(
                fun() ->
                    Resp = ?MODULE:send_receipt(Data, OnionCompactKey, Type, os:system_time(nanosecond), RSSI, Stream),
                    case Resp of
                        {error, Reason} ->
                            lager:error("not sending RF because we could not deliver receipt: ~p", [Reason]);
                        ok ->
                            timer:sleep(rand:uniform(?TX_RAND_SLEEP) + ?TX_MIN_SLEEP),
                            _ = gen_udp:send(Socket, IP, Port, Packet)
                    end
                end
            ),
            State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|State#state.pending_transmits]}
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    NewState.

-spec try_decrypt(binary(), binary(), binary(), binary(), function()) -> {ok, binary(), binary()} | {error, any()}.
try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
        {error, _}=Err ->
            Err;
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
            {error, too_many_pocs}
    end.


% This is an onion packet cause oui/device_id = 0
handle_packet(#helium_LongFiResp_pb{id=_ID, kind={rx, #helium_LongFiRxPacket_pb{oui=0, device_id=1, rssi=RSSI, payload=Payload}}}, State) ->
    <<IV:2/binary,
      OnionCompactKey:33/binary,
      Tag:4/binary,
      CipherText/binary>> = Payload,
    decrypt(radio, IV, OnionCompactKey, Tag, CipherText, erlang:trunc(RSSI), undefined, State);
handle_packet(Resp = #helium_LongFiResp_pb{kind={rx, _}}, #state{miner_name=Name}=State) ->
    erlang:spawn(?MODULE, send_to_router, [Name, Resp]),
    State;
handle_packet(#helium_LongFiResp_pb{id=ID, kind={tx_status, #helium_LongFiTxStatus_pb{success=Success}}}, #state{pending_transmits=Pending}=State) ->
    case lists:keyfind(ID, 1, Pending) of
        {ID, Ref} ->
            lager:info("packet transmission ~p completed with success ~p", [ID, Success]),
            erlang:cancel_timer(Ref);
        false ->
            lager:info("got unknown packet transmission response ~p with success ~p", [ID, Success])
    end,
    State#state{pending_transmits=lists:keydelete(ID, 1, Pending)};
handle_packet(#helium_LongFiResp_pb{id=_ID, kind={parse_err, Error}}, State) ->
    lager:warning("parse error (ID= ~p): ~p", [_ID, Error]),
    State;
handle_packet(#helium_LongFiResp_pb{id=_ID, kind=_Kind}, State) ->
    lager:warning("unknown (ID= ~p) (kind= ~p) packet ~p", [_ID, _Kind]),
    State.


-spec tx_params(integer(), Fragment :: boolean()) -> {atom(), atom()}.
tx_params(_, true) ->
    {application:get_env(miner, poc_spreading_factor, 'SF10'), 'CR4_5'};
tx_params(Len, false) when Len < 54 ->
    {'SF9', 'CR4_6'};
tx_params(Len, false) when Len < 83 ->
    {'SF8', 'CR4_8'};
tx_params(Len, false) when Len < 99 ->
    {'SF8', 'CR4_7'};
tx_params(Len, false) when Len < 115 ->
    {'SF8', 'CR4_6'};
tx_params(Len, false) when Len < 139 ->
    {'SF8', 'CR4_5'};
tx_params(Len, false) when Len < 160 ->
    {'SF7', 'CR4_8'};
tx_params(_, false) ->
    %% onion packets won't be this big, but this will top out around 180 bytes
    {'SF7', 'CR4_7'}.
