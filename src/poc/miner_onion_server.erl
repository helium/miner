%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion Server ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_server).

-behavior(gen_server).

-include("pb/concentrate_pb.hrl").

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
-define(TX_COUNT, 3).
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

handle_call(compact_key, _From, State=#state{compact_key=CK}) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call({send, Data}, _From, State=#state{udp_socket=Socket, packet_id=ID}) ->
    Channel = trunc(lists:nth(rand:uniform(length(?CHANNELS)), ?CHANNELS)),
    {Spreading, CodeRate} = tx_params(byte_size(Data)),
    lager:info("Sending ~p bytes on channel ~p at ~p ~p", [byte_size(Data), Channel, Spreading, CodeRate]),
    Ref = erlang:send_after(5000, self(), {tx_timeout, ID}),
    R = gen_udp:send(Socket, State#state.udp_send_ip, State#state.udp_send_port,
                     concentrate_pb:encode_msg(#miner_Req_pb{
                                                  id=ID,
                                                  kind={tx, #miner_TxReq_pb{payload=Data,
                                                                                       bandwidth='BW125kHz',
                                                                                       spreading=Spreading,
                                                                                       coderate=CodeRate,
                                                                                       freq=Channel,
                                                                                       radio='R0',
                                                                                       power=?TX_POWER}}})),
    {reply, R, State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|State#state.pending_transmits]}};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({decrypt, <<IV:2/binary,
                        OnionCompactKey:33/binary,
                        Tag:4/binary,
                        CipherText/binary>>, Pid}, State) ->
    NewState = decrypt(IV, OnionCompactKey, Tag, CipherText, State, p2p, 0, Pid),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Packet}, State = #state{udp_send_ip=IP, udp_send_port=Port}) ->
    NewState = try concentrate_pb:decode_msg(Packet, miner_Resp_pb) of
                   RxPacket ->
                       handle_packet(RxPacket, State)
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
decrypt(IV, OnionCompactKey, Tag, CipherText, State=#state{ecdh_fun=ECDHFun, udp_socket=Socket, udp_send_ip=IP, udp_send_port=Port, packet_id=ID}, Type, RSSI, Stream) ->
    NewState = case seen_ciphertext(CipherText, State) of
        false ->
            case try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
                           error ->
                               _ = erlang:spawn(?MODULE, send_witness, [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>), OnionCompactKey, os:system_time(nanosecond), RSSI]),
                               lager:info("could not decrypt packet received via ~p", [Type]),
                               record_ciphertext(CipherText, State);
                           {ok, Data, NextPacket} ->
                               lager:info("decrypted a layer: ~w received via ~p~n", [Data, Type]),
                               _ = erlang:spawn(?MODULE, send_receipt, [Data, OnionCompactKey, Type, os:system_time(nanosecond), RSSI, Stream]),
                               Payload = <<0:32/integer, %% broadcast packet
                                           1:8/integer, %% onion packet
                                           NextPacket/binary>>,
                               Ref = erlang:send_after(5000, self(), {tx_timeout, ID}),
                               spawn(fun() ->
                                             [ begin
                                                   timer:sleep(rand:uniform(?TX_RAND_SLEEP)),
                                                   Channel = trunc(lists:nth(rand:uniform(length(?CHANNELS)), ?CHANNELS)),
                                                   {Spreading, CodeRate} = tx_params(byte_size(Payload)),
                                                   lager:info("Relaying ~p bytes on channel ~p at ~p ~p", [byte_size(Payload), Channel, Spreading, CodeRate]),
                                                   gen_udp:send(Socket, IP, Port,
                                                                concentrate_pb:encode_msg(#miner_Req_pb{
                                                                                             id=ID,
                                                                                             kind={tx, #miner_TxReq_pb{payload=Payload,
                                                                                                                       bandwidth='BW125kHz',
                                                                                                                       spreading=Spreading,
                                                                                                                       coderate=CodeRate,
                                                                                                                       freq=Channel,
                                                                                                                       radio='R0',
                                                                                                                       power=?TX_POWER}}}))
                                               end || _ <- lists:seq(1, ?TX_COUNT)]
                                     end),
                               record_ciphertext(CipherText, State#state{packet_id=((ID+1) band 16#ffffffff), pending_transmits=[{ID, Ref}|State#state.pending_transmits]})
                       end;
        true ->
            State
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    NewState.

record_ciphertext(Text, State) ->
    State#state{ciphertexts = lists:sublist([Text | State#state.ciphertexts], 20)}.

seen_ciphertext(Text, State) ->
    lists:member(Text, State#state.ciphertexts).

try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    try blockchain_poc_packet:decrypt(<<IV/binary, OnionCompactKey/binary, Tag/binary, CipherText/binary>>, ECDHFun) of
        error ->
            error;
        {Payload, NextLayer} ->
            {ok, Payload, NextLayer}
    catch _:_ ->
              error
    end.

handle_packet(#miner_Resp_pb{kind={rx_packet, #miner_RxPacket_pb{payload =
                                 <<0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
                                   1:8/integer, %% onions are type 1 broadcast?
                                   IV:2/binary,
                                   OnionCompactKey:33/binary,
                                   Tag:4/binary,
                                   CipherText/binary>>,
                                rssi=RSSI, crc_check=true}}}, State) ->
    decrypt(IV, OnionCompactKey, Tag, CipherText, State, radio, trunc(RSSI), undefined);
handle_packet(#miner_Resp_pb{kind={rx_packet, #miner_RxPacket_pb{payload = Packet,
                                 rssi=RSSI, if_chain=Channel, crc_check=CRC}}},
              #state{udp_socket=Socket}=State) ->
    %% some other packet, just forward it to gw-demo for now
    gen_udp:send(Socket, {127,0,0,1}, 6789, <<?READ_RADIO_PACKET_EXTENDED:8/integer, (trunc(RSSI)):8/integer-signed, Channel:8/integer-unsigned, (crc_status(CRC)):8/integer-unsigned, Packet/binary>>),
    State;
handle_packet(#miner_Resp_pb{id=ID, kind={tx, #miner_TxResp_pb{success=Success}}}, State=#state{pending_transmits=Pending}) ->
    case lists:keyfind(ID, 1, Pending) of
        {ID, Ref} ->
            lager:info("Packet transmission ~p completed with success ~p", [ID, Success]),
            erlang:cancel_timer(Ref);
        false ->
            lager:info("Got unknown packet transmission response ~p with success ~p", [ID, Success])
    end,
    State#state{pending_transmits=lists:keydelete(ID, 1, Pending)};
handle_packet(#miner_Resp_pb{id=_ID, kind={parse_err, ErrorString}}, State) ->
    lager:warning("parse error from concentrator: ~s", [ErrorString]),
    State;
handle_packet(Packet, State) ->
    lager:warning("unknown packet ~p", [Packet]),
    State.

crc_status(true) -> 1;
crc_status(false) -> 0.

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
    %% onion packets won't be this big, but this will top out around 180 bytes
    {'SF7', 'CR4_7'}.
