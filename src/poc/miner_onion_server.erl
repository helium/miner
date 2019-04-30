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
    send/1,
    decrypt/1,
    send_receipt/5,
    send_witness/4
]).

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

-define(WRITE_RADIO_PACKET, 16#0).
-define(WRITE_RADIO_PACKET_ACK, 16#80).
-define(READ_RADIO_PACKET, 16#81).
-define(READ_RADIO_PACKET_EXTENDED, 16#82).

-define(BLOCK_RETRY_COUNT, 10).

-record(state, {
    host :: string(),
    port :: integer(),
    socket :: gen_tcp:socket() | undefined,
    udp_socket :: gen_udp:socket(),
    compact_key :: ecc_compact:compact_key(),
    ecdh_fun,
    sender :: undefined | {pid(), term()}
}).

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
-spec decrypt(binary()) -> ok.
decrypt(Onion) ->
    gen_server:cast(?MODULE, {decrypt, Onion}).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer()) -> ok.
send_receipt(_Data, _OnionCompactKey, Type, Time, RSSI) ->
    ok = blockchain_event:add_handler(self()),
    send_receipt(_Data, _OnionCompactKey, Type, Time, RSSI, ?BLOCK_RETRY_COUNT).

-spec send_receipt(binary(), libp2p_crypto:pubkey_bin(), radio | p2p, pos_integer(), integer(), non_neg_integer()) -> ok.
send_receipt(_Data, _OnionCompactKey, _Type, _Time, _RSSI, 0) ->
    lager:error("failed to send receipts, max retry");
send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Retry) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionKeyHash = crypto:hash(sha256, OnionCompactKey),
    case blockchain_ledger_v1:find_poc(OnionKeyHash, Ledger) of
        {error, _Reason} ->
            lager:warning("no gateway found with onion ~p (~p)", [OnionCompactKey, _Reason]),
            ok = wait_until_next_block(),
            send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Retry-1);
        {ok, PoCs} ->
            Results = lists:foldl(
                fun(PoC, Acc) ->
                    Challenger = blockchain_ledger_poc_v1:challenger(PoC),
                    Address = blockchain_swarm:pubkey_bin(),
                    Receipt0 = blockchain_poc_receipt_v1:new(Address, Time, RSSI, Data, Type),
                    {ok, _, SigFun} = blockchain_swarm:keys(),
                    Receipt1 = blockchain_poc_receipt_v1:sign(Receipt0, SigFun),
                    EncodedReceipt = blockchain_poc_response_v1:encode(Receipt1),

                    P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
                    case miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                        {error, _Reason} ->
                            lager:error("failed to dial challenger ~p (~p)", [Challenger, _Reason]),
                            [error|Acc];
                        {ok, Stream} ->
                            _ = miner_poc_handler:send(Stream, EncodedReceipt),
                            Acc
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
                    send_receipt(Data, OnionCompactKey, Type, Time, RSSI, Retry-1)
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
                    {ok, _, SigFun} = blockchain_swarm:keys(),
                    Witness1 = blockchain_poc_witness_v1:sign(Witness0, SigFun),
                    EncodedWitness = blockchain_poc_response_v1:encode(Witness1),

                    P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
                    case miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []) of
                        {error, _Reason} ->
                            lager:warning("failed to dial challenger ~p (~p)", [Challenger, _Reason]),
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
    UDPPort = maps:get(radio_udp_port, Args),
    {ok, UDP} = gen_udp:open(UDPPort, [{ip, {127,0,0,1}}, binary, {active, once}, {reuseaddr, true}]),
    State = #state{
        host = maps:get(radio_host, Args),
        port = maps:get(radio_tcp_port, Args),
        compact_key = blockchain_swarm:pubkey_bin(),
        udp_socket = UDP,
        ecdh_fun = maps:get(ecdh_fun, Args)
    },
    self() ! connect,
    lager:info("init with ~p", [Args]),
    {ok, State}.

handle_call(compact_key, _From, State=#state{compact_key=CK}) when CK /= undefined ->
    {reply, {ok, CK}, State};
handle_call(_Msg, _From, #state{socket=undefined}=State) ->
    {reply, {error, socket_undefined}, State};
handle_call({send, Data}, From, State=#state{socket=Socket}) ->
    R = gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET, Data/binary>>),
    {reply, R, State#state{sender=From}};
handle_call(socket, _From, State=#state{socket=Socket}) ->
    {reply, {ok, Socket}, State};
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast({decrypt, <<IV:2/binary,
                        OnionCompactKey:33/binary,
                        Tag:4/binary,
                        CipherText/binary>>}
            ,#state{ecdh_fun=ECDHFun, socket=Socket}=State) ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket, p2p, 0),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, #state{host=Host, port=Port}=State) ->
    Opts = [binary, {packet, 2}, {active, once}, {nodelay, true}],
    case gen_tcp:connect(Host, Port, Opts) of
        {ok, Socket} ->
            {noreply, State#state{socket=Socket}};
        {error, _Reason} ->
            lager:warning("fail to open socket (~p:~p) ~p", [Host, Port, _Reason]),
             _ = reconnect(),
            {noreply, State}
    end;
handle_info({tcp, Socket, <<Byte:8/integer, _/binary>>}, State)
  when Byte == ?READ_RADIO_PACKET; Byte == ?READ_RADIO_PACKET_EXTENDED ->
    %% the packets received from the 1310 are garbage on the rev3 boards, so just null route them for now
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info({tcp, Socket, Packet}, State) ->
    NewState = handle_packet(Packet, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, NewState};
handle_info({udp, Socket, _Host, _Port, Packet}, State) ->
    NewState = handle_packet(Packet, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, NewState};
handle_info({tcp_closed, _Socket}, State) ->
    lager:warning("tcp_closed"),
    _ = reconnect(),
    {noreply, State};
handle_info({tcp_error, _Socket, _Reason}, State) ->
    lager:error("tcp_error, reason: ~p", [_Reason]),
    _ = reconnect(),
    {noreply, State};
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
        {blockchain_event, {add_block, _BlockHash, _}} ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket, Type, RSSI) ->
    case try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
        error ->
            _ = erlang:spawn(?MODULE, send_witness, [crypto:hash(sha256, <<Tag/binary, CipherText/binary>>), OnionCompactKey, os:system_time(nanosecond), RSSI]),
            lager:info("could not decrypt packet received via ~p", [Type]);
        {ok, Data, NextPacket} ->
            lager:info("decrypted a layer: ~w received via ~p~n", [Data, Type]),
            _ = erlang:spawn(?MODULE, send_receipt, [Data, OnionCompactKey, Type, os:system_time(nanosecond), RSSI]),
            gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET,
                                   0:32/integer, %% broadcast packet
                                   1:8/integer, %% onion packet
                                   NextPacket/binary>>)
    end,
    ok = inet:setopts(Socket, [{active, once}]).

try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    case blockchain_poc_packet:decrypt(<<IV/binary, OnionCompactKey/binary, Tag/binary, CipherText/binary>>, ECDHFun) of
        error ->
            error;
        {Payload, NextLayer} ->
            {ok, Payload, NextLayer}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec reconnect() -> reference().
reconnect() ->
    lager:warning("trying to reconnect in 5s"),
    erlang:send_after(timer:seconds(5), self(), connect).

handle_packet(<<?READ_RADIO_PACKET,
                0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
                1:8/integer, %% onions are type 1 broadcast?
                IV:2/binary,
                OnionCompactKey:33/binary,
                Tag:4/binary,
                CipherText/binary>>,
            #state{ecdh_fun=ECDHFun, socket=Socket}=State) ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket, radio, 0),
    State;
handle_packet(<<?READ_RADIO_PACKET_EXTENDED,
                             RSSI:8/integer-signed,
                             _Channel:8/integer-unsigned,
                             CRCStatus:8/integer,
                             0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
                             1:8/integer, %% onions are type 1 broadcast?
                             IV:2/binary,
                             OnionCompactKey:33/binary,
                             Tag:4/binary,
                             CipherText/binary>>,
              #state{ecdh_fun=ECDHFun, socket=Socket}=State) when CRCStatus == 1 ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket, radio, RSSI),
    State;
handle_packet(<<?READ_RADIO_PACKET, _/binary>> = Packet, #state{udp_socket=UDP}=State) ->
    %% some other packet, just forward it to gw-demo for now
    gen_udp:send(UDP, {127,0,0,1}, 6789, Packet),
    State;
handle_packet(<<?READ_RADIO_PACKET_EXTENDED, _/binary>> = Packet, #state{udp_socket=UDP}=State) ->
    %% some other packet, just forward it to gw-demo for now
    gen_udp:send(UDP, {127,0,0,1}, 6789, Packet),
    State;
handle_packet(<<?WRITE_RADIO_PACKET_ACK>>, State) ->
    lager:info("received ACK from Radio"),
    case State#state.sender of
        undefined -> ok;
        From ->
            gen_server:reply(From, ok)
    end,
    State#state{sender=undefined};
handle_packet(Packet, State) ->
    lager:warning("unknown packet ~p", [Packet]),
    State.

