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
    construct_onion/2,
    decrypt/1,
    send_receipt/2,
    send_witness/2
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
-spec construct_onion({ecc_compact:private_key(), ecc_compact:compact_key()}, [{binary(), ecc_compact:compact_key()}]) -> binary().
construct_onion({PvtOnionKey, OnionCompactKey}, DataAndPubkeys) ->
    IV = crypto:strong_rand_bytes(12),
    <<IV/binary, (libp2p_crypto:pubkey_to_bin(OnionCompactKey))/binary, (construct_onion(DataAndPubkeys, PvtOnionKey, OnionCompactKey, IV))/binary>>.

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
-spec send_receipt(binary(), libp2p_crypto:pubkey()) -> ok.
send_receipt(Data, OnionCompactKey) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    OnionCompactKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
    Gateways = maps:filter(
        fun(_Address, Info) ->
            case blockchain_ledger_gateway_v1:last_poc_info(Info) of
                {_, OnionCompactKeyHash} -> true;
                _ -> false
            end
        end,
        blockchain_ledger_v1:active_gateways(Ledger)
    ),
    case maps:keys(Gateways) of
        [Challenger] ->
            Address = blockchain_swarm:pubkey_bin(),
            Receipt0 = blockchain_poc_receipt_v1:new(Address, os:system_time(), 0, Data),
            {ok, _, SigFun} = blockchain_swarm:keys(),
            Receipt1 = blockchain_poc_receipt_v1:sign(Receipt0, SigFun),
            EncodedReceipt = blockchain_poc_receipt_v1:encode(Receipt1),

            P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
            {ok, Stream} = miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []),
            _ = miner_poc_handler:send(Stream, EncodedReceipt);
        _Other ->
            lager:warning("not gateway found with onion ~p (~p)", [OnionCompactKey, _Other])
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec send_witness(binary(), libp2p_crypto:pubkey()) -> ok.
send_witness(Data, OnionCompactKey) ->
    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),
    Hash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(OnionCompactKey)),
    Gateways = maps:filter(
        fun(_Address, Info) ->
            case blockchain_ledger_gateway_v1:last_poc_info(Info) of
                {_, Hash} -> true;
                _ -> false
            end
        end,
        blockchain_ledger_v1:active_gateways(Ledger)
    ),
    case maps:keys(Gateways) of
        [Challenger] ->
            Address = blockchain_swarm:pubkey_bin(),
            Receipt0 = blockchain_poc_witness_v1:new(Address, os:system_time(), 0, Data),
            {ok, _, SigFun} = blockchain_swarm:keys(),
            Receipt1 = blockchain_poc_witness_v1:sign(Receipt0, SigFun),
            EncodedReceipt = blockchain_poc_witness_v1:encode(Receipt1),

            P2P = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
            {ok, Stream} = miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []),
            _ = miner_poc_handler:send(Stream, EncodedReceipt);
        _Other ->
            lager:warning("not gateway found with onion ~p (~p)", [OnionCompactKey, _Other])
    end,
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    {ok, UDP} = gen_udp:open(5678, [{ip, {127,0,0,1}}, binary, {active, once}, {reuseaddr, true}]),
    State = #state{
        host = maps:get(radio_host, Args),
        port = maps:get(radio_port, Args),
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

handle_cast({decrypt, <<IV:12/binary,
                        OnionCompactKey:33/binary,
                        Tag:4/binary,
                        CipherText/binary>>}
            ,#state{ecdh_fun=ECDHFun, socket=Socket}=State) ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket),
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
handle_info({_, Socket, <<?READ_RADIO_PACKET,
                             0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
                             1:8/integer, %% onions are type 1 broadcast?
                             IV:12/binary,
                             OnionCompactKey:33/binary,
                             Tag:4/binary,
                             CipherText/binary>>},
            #state{ecdh_fun=ECDHFun, socket=Socket}=State) ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info({_, Socket, <<?READ_RADIO_PACKET_EXTENDED,
                             _RSSI:8/integer-signed,
                             _Channel:8/integer-unsigned,
                             CRCStatus:8/integer,
                             0:32/integer-unsigned-little, %% all onion packets start with all 0s because broadcast
                             1:8/integer, %% onions are type 1 broadcast?
                             IV:12/binary,
                             OnionCompactKey:33/binary,
                             Tag:4/binary,
                             CipherText/binary>>},
            #state{ecdh_fun=ECDHFun, socket=Socket}=State) when CRCStatus == 1 ->
    ok = decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info({_, Socket, <<?READ_RADIO_PACKET, _/binary>> = Packet}, #state{udp_socket=UDP}=State) ->
    %% some other packet, just forward it to gw-demo for now
    gen_udp:send(UDP, {127,0,0,1}, 6789, Packet),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info({_, Socket, <<?READ_RADIO_PACKET_EXTENDED, _/binary>> = Packet}, #state{udp_socket=UDP}=State) ->
    %% some other packet, just forward it to gw-demo for now
    gen_udp:send(UDP, {127,0,0,1}, 6789, Packet),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

%% handle ack from radio
handle_info({tcp, Socket, <<?WRITE_RADIO_PACKET_ACK>>}, State) ->
    lager:info("received ACK from Radio"),
    case State#state.sender of
        undefined -> ok;
        From ->
            gen_server:reply(From, ok)
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State#state{sender=undefined}};
handle_info({tcp, Socket, Packet}, State) ->
    lager:warning("got unhandled TCP packet ~p", [Packet]),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
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
decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun, Socket) ->
    case try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
        error ->
            _ = erlang:spawn(?MODULE, send_witness, [crypto:hash(sha256, CipherText), OnionCompactKey]),
            lager:info("could not decrypt");
        {ok, Data, NextPacket} ->
            lager:info("decrypted a layer: ~p~n", [Data]),
            _ = erlang:spawn(?MODULE, send_receipt, [Data, OnionCompactKey]),
            gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET,
                                   0:32/integer, %% broadcast packet
                                   1:8/integer, %% onion packet
                                   NextPacket/binary>>)
    end,
    ok = inet:setopts(Socket, [{active, once}]).

try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) ->
    AAD = <<IV/binary, OnionCompactKey/binary>>,
    PubKey = libp2p_crypto:bin_to_pubkey(OnionCompactKey),
    SharedKey = ECDHFun(PubKey),
    case crypto:block_decrypt(aes_gcm, SharedKey, IV, {AAD, CipherText, Tag}) of
        error ->
            error;
        <<Size:8/integer-unsigned, Data:Size/binary, InnerLayer/binary>> ->
            {ok, Data, <<AAD/binary, InnerLayer/binary>>}
    end.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec reconnect() -> reference().
reconnect() ->
    lager:warning("trying to reconnect in 5s"),
    erlang:send_after(timer:seconds(5), self(), connect).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec construct_onion([{binary(), ecc_compact:compact_key()}] | [], ecc_compact:private_key(),
                      ecc_compact:compact_key(),
                      binary()) -> binary().
construct_onion([], _, _, _) ->
    %% as packets are decrypted we add deterministic padding to keep the packet
    %% size the same, but we don't need to do that here
    <<>>;
construct_onion([{Data, PubKey} | Tail], OnionECDH, OnionCompactKey, IV) ->
    SecretKey = OnionECDH(libp2p_crypto:bin_to_pubkey(PubKey)),
    InnerLayer = construct_onion(Tail, OnionECDH, OnionCompactKey, IV),
    {CipherText, Tag} = crypto:block_encrypt(aes_gcm,
                                             SecretKey,
                                             IV, {<<IV/binary, (libp2p_crypto:pubkey_to_bin(OnionCompactKey))/binary>>,
                                                  <<(byte_size(Data)):8/integer, Data/binary, InnerLayer/binary>>, 4}),
    <<Tag:4/binary, CipherText/binary>>.
