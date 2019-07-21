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
    send_witness/4
]).

-ifdef(TEST).
-define(TX_RAND_SLEEP, 1).
-define(TX_COUNT, 1).
-else.
-define(TX_RAND_SLEEP, 15000).
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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send(binary()) -> ok.
send(Data) ->
    gen_server:call(?MODULE, {send, Data}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec decrypt(binary(), pid()) -> ok.
decrypt(Onion, Stream) ->
    gen_server:cast(?MODULE, {decrypt, Onion, Stream}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid()) -> ok.
send_receipt(_Data, _OnionCompactKey, Type, Time, RSSI, Stream) ->
    ok = blockchain_event:add_handler(self()),
    send_receipt(_Data, _OnionCompactKey, Type, Time, RSSI, Stream, ?BLOCK_RETRY_COUNT).

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), undefined | pid(), non_neg_integer()) -> ok.
send_receipt(_Data, _OnionCompactKey, _Type, _Time, _RSSI, _Stream, 0) ->
    lager:error("failed to send receipts, max retry");
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
                    Challenger = blockchain_ledger_poc_v1:challenger(PoC),
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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec  send_witness(binary(), libp2p_crypto:pubkey_bin(), pos_integer(), integer()) -> ok.
send_witness(_Data, _OnionCompactKey, Time, RSSI) ->
    ok = blockchain_event:add_handler(self()),
    send_witness(_Data, _OnionCompactKey, Time, RSSI, ?BLOCK_RETRY_COUNT).

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
            lists:foreach(
                fun(PoC) ->
                    Challenger = blockchain_ledger_poc_v1:challenger(PoC),
                    Address = blockchain_swarm:pubkey_bin(),
                    Witness0 = blockchain_poc_witness_v1:new(Address, Time, RSSI, Data),
                    {ok, _, SigFun, _ECDHFun} = blockchain_swarm:keys(),
                    Witness1 = blockchain_poc_witness_v1:sign(Witness0, SigFun),
                    EncodedWitness = blockchain_poc_response_v1:encode(Witness1),

                    P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
                    case miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                        {error, _Reason} ->
                            lager:warning("failed to dial challenger ~p (~p)", [P2P, _Reason]),
                            ok = wait_until_next_block(),
                            send_witness(Data, OnionCompactKey, Time, RSSI, Retry-1);
                        {ok, Stream} ->
                            _ = miner_poc_handler:send(Stream, EncodedWitness)
                    end
                end,
                PoCs
            )
    end,
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    UDPPort = maps:get(radio_udp_bind_port, Args),
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPSendPort = maps:get(radio_udp_send_port, Args),
    UDPSendIP = maps:get(radio_udp_send_ip, Args),
    {ok, UDP} = gen_udp:open(UDPPort, [{ip, UDPIP}, {port, UDPPort}, binary, {active, once}, {reuseaddr, true}]),
    State = #state{
        compact_key = blockchain_swarm:pubkey_bin(),
        udp_socket = UDP,
        udp_send_port = UDPSendPort,
        udp_send_ip = UDPSendIP,
        ecdh_fun = maps:get(ecdh_fun, Args)
    },
    lager:info("init with ~p", [Args]),
    {ok, State}.

handle_call(compact_key, _From, #state{compact_key=CK}=State) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call({send, Data}, _From, #state{udp_socket=Socket, udp_send_ip=IP, udp_send_port=Port,
                                        packet_id=ID, pending_transmits=Pendings }=State) ->
    {Spreading, _CodeRate} = tx_params(erlang:byte_size(Data)),
    Ref = erlang:send_after(5000, self(), {tx_timeout, ID}),
    UpLink = #helium_LongFiTxUplinkPacket_pb{
        spreading=Spreading,
        payload=Data
    },
    Req = #helium_LongFiReq_pb{id=ID, kind={tx_uplink, UpLink}},
    lager:info("sending ~p", [Req]),
    Packet = helium_longfi_pb:encode_msg(Req),
    R = gen_udp:send(Socket, IP, Port, Packet),
    {reply, R, State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|Pendings]}};
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
    NewState =
        try helium_longfi_pb:decode_msg(Packet, helium_LongFiResp_pb) of
            Resp ->
                handle_packet(Resp, Packet, State)
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

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec wait_until_next_block() -> ok.
wait_until_next_block() ->
    receive
        {blockchain_event, {add_block, _BlockHash, _, _}} ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
decrypt(Type, IV, OnionCompactKey, Tag, CipherText, RSSI, Stream, #state{ecdh_fun=ECDHFun,
                                                                         udp_socket=Socket,
                                                                         udp_send_ip=IP,
                                                                         udp_send_port=Port,
                                                                         packet_id=ID}=State) ->
    NewState = case try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
        error ->
            _ = erlang:spawn(
                ?MODULE,
                send_witness,
                [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>),
                 OnionCompactKey,
                 os:system_time(nanosecond), RSSI]
            ),
            lager:info("could not decrypt packet received via ~p", [Type]),
            State;
        {ok, Data, NextPacket} ->
            lager:info("decrypted a layer: ~w received via ~p~n", [Data, Type]),
            _ = erlang:spawn(
                ?MODULE,
                send_receipt,
                [Data,
                 OnionCompactKey,
                 Type,
                 os:system_time(nanosecond),
                 RSSI,
                 Stream]
            ),

            Ref = erlang:send_after(5000, self(), {tx_timeout, ID}),
            Payload = <<0:32/integer, %% broadcast packet
                     1:8/integer, %% onion packet
                     NextPacket/binary>>,
            {Spreading, _CodeRate} = tx_params(erlang:byte_size(Payload)),
            UpLink = #helium_LongFiTxUplinkPacket_pb{
                spreading=Spreading,
                payload=Payload
            },
            Req = #helium_LongFiReq_pb{id=ID, kind={tx_uplink, UpLink}},
            lager:info("sending ~p", [Req]),
            Packet = helium_longfi_pb:encode_msg(Req),
            _ = gen_udp:send(Socket, IP, Port, Packet),
            State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|State#state.pending_transmits]}
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    NewState.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    try blockchain_poc_packet:decrypt(<<IV/binary, OnionCompactKey/binary, Tag/binary, CipherText/binary>>, ECDHFun) of
        error ->
            error;
        {Payload, NextLayer} ->
            {ok, Payload, NextLayer}
    catch _:_ ->
              error
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
handle_packet(#helium_LongFiResp_pb{id=ID, kind=Kind}, _Packet, State) ->
    handle_packet(ID, Kind, _Packet, State).

% This is aan onion packet cause oui/device_id = 0
handle_packet(_ID, {rx, #helium_LongFiRxPacket_pb{crc_check=true, oui=0, device_id=0, rssi=RSSI, payload=Payload}}, _Packet, State) ->
    <<0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
      1:8/integer, %% onions are type 1 broadcast?
      IV:2/binary,
      OnionCompactKey:33/binary,
      Tag:4/binary,
      CipherText/binary>> = Payload,
    decrypt(radio, IV, OnionCompactKey, Tag, CipherText, erlang:trunc(RSSI), undefined, State);
handle_packet(_ID, {rx, #helium_LongFiRxPacket_pb{oui=OUI}}, Packet, State) ->
    erlang:spawn(fun() ->
        Chain = blockchain_worker:blockchain(),
        Ledger = blockchain:ledger(Chain),
        case blockchain_ledger_v1:find_routing(OUI, Ledger) of
            {error, _Reason} ->
                ok;
            {ok, Routing} ->
                Addresses = blockchain_ledger_routing_v1:addresses(Routing),
                Swarm = blockchain_swarm:swarm(),
                lists:foreach(
                    fun(Address) ->
                        Result = libp2p_swarm:dial_framed_stream(Swarm,
                                                                 Address,
                                                                 router_handler:version(),
                                                                 router_handler,
                                                                 [Packet]),
                        case Result of
                            {ok, _} -> lager:info("sent packet ~p to ~p", [Packet, Address]);
                            {error, _Reason} -> lager:error("failed to send packet ~p to ~p (~p)", [Packet, Address, _Reason])
                        end
                    end,
                    Addresses
                )
        end
    end),
    State;
handle_packet(ID, {tx_status, #helium_LongFiTxStatus_pb{success=Success}}, _Packet, #state{pending_transmits=Pending}=State) ->
    case lists:keyfind(ID, 1, Pending) of
        {ID, Ref} ->
            lager:info("packet transmission ~p completed with success ~p", [ID, Success]),
            erlang:cancel_timer(Ref);
        false ->
            lager:info("got unknown packet transmission response ~p with success ~p", [ID, Success])
    end,
    State#state{pending_transmits=lists:keydelete(ID, 1, Pending)};
handle_packet(_ID, {parse_err, Error}, _Packet, State) ->
    lager:warning("parse error (ID= ~p): ~p", [_ID, Error]),
    State;
handle_packet(_ID, {_Kind, _Packet}, _Packet, State) ->
    lager:warning("unknown (ID= ~p) (kind= ~p) packet ~p", [_ID, _Kind, _Packet]),
    State.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec tx_params(integer()) -> {atom(), atom()}.
tx_params(Len) when Len < 54 ->
    {'SF9', 'CR4_6'};
tx_params(Len) when Len < 83 ->
    {'SF8', 'CR4_8'};
tx_params(Len) when Len < 99 ->
    {'SF8', 'CR4_7'};
tx_params(Len) when Len < 115 ->
    {'SF8', 'CR4_6'};
tx_params(Len) when Len < 139 ->
    {'SF8', 'CR4_5'};
tx_params(Len) when Len < 160 ->
    {'SF7', 'CR4_8'};
tx_params(_) ->
    {'SF10', 'CR4_8'}.
%tx_params(Len) when Len < 54 ->
    %{'SF9', 'CR4_6'};
%tx_params(Len) when Len < 83 ->
    %{'SF8', 'CR4_8'};
%tx_params(Len) when Len < 99 ->
    %{'SF8', 'CR4_7'};
%tx_params(Len) when Len < 115 ->
    %{'SF8', 'CR4_6'};
%tx_params(Len) when Len < 139 ->
    %{'SF8', 'CR4_5'};
%tx_params(Len) when Len < 160 ->
    %{'SF7', 'CR4_8'};
%tx_params(_) ->
    %% onion packets won't be this big, but this will top out around 180 bytes
    %{'SF7', 'CR4_7'}.
