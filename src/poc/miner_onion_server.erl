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
    start_link/4,
    send/1,
    socket/0,
    compact_key/0,
    construct_onion/1,
    decrypt/1,
    send_receipt/2
]).

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

-record(state, {
    host :: string(),
    port :: integer(),
    socket :: gen_tcp:socket(),
    compact_key :: ecc_compact:compact_key(),
    privkey,
    sender :: undefined | {pid(), term()},
    controlling_process :: pid()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Host, Port, CompactKey, PrivateKey) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Host, Port, CompactKey, PrivateKey], []).

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
-spec socket() -> {ok, gen_tcp:socket()}.
socket() ->
    gen_server:call(?MODULE, socket).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec compact_key() -> {ok, ecc_compact:compact_key()}.
compact_key() ->
    gen_server:call(?MODULE, compact_key).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec construct_onion([{binary(), ecc_compact:compact_key()}]) -> binary().
construct_onion(DataAndPubkeys) ->
    {ok, PvtOnionKey, OnionCompactKey} = ecc_compact:generate_key(),
    IV = crypto:strong_rand_bytes(12),
    <<IV/binary, OnionCompactKey/binary, (construct_onion(DataAndPubkeys, PvtOnionKey, OnionCompactKey, IV))/binary>>.

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
-spec send_receipt(binary(), binary()) -> ok.
send_receipt(IV, Data) ->
    Map = erlang:binary_to_term(Data),
    Challenger = maps:get(challenger, Map),
    P2P = libp2p_crypto:address_to_p2p(Challenger),
    {ok, Stream} = miner_poc:dial_framed_stream(blockchain_swarm:swarm(), P2P, []),
    Address = blockchain_swarm:address(),
    Receipt0 = blockchain_poc_receipt_v1:new(Address, os:system_time(), IV),
    {ok, _, SigFun} = blockchain_swarm:keys(),
    Receipt1 = blockchain_poc_receipt_v1:sign(Receipt0, SigFun),
    EncodedReceipt = blockchain_poc_receipt_v1:encode(Receipt1),
    _ = miner_poc_handler:send(Stream, EncodedReceipt),
    ok.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([Host, Port, CompactKey, PrivateKey]=_Args) ->
    State = #state{
        host=Host,
        port=Port,
        compact_key=CompactKey,
        privkey=PrivateKey
    },
    self() ! connect,
    lager:info("init with ~p", [_Args]),
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
                        OnionCompactKey:32/binary,
                        Tag:4/binary,
                        CipherText/binary>>}
            ,#state{privkey=PrivKey, socket=Socket}=State) ->
    AAD = <<IV/binary, OnionCompactKey/binary>>,
    PubKey = ecc_compact:recover_key(OnionCompactKey),
    SharedKey = public_key:compute_key(element(1, PubKey), PrivKey),
    case crypto:block_decrypt(aes_gcm, SharedKey, IV, {AAD, CipherText, Tag}) of
        error ->
            lager:error("could not decrypt");
        <<Size:8/integer-unsigned, Data:Size/binary, InnerLayer/binary>> ->
            lager:info("decrypted a layer: ~p~n", [Data]),
            _ = erlang:spawn(?MODULE, send_receipt, [IV, Data]),
            gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET, AAD/binary, InnerLayer/binary>>)
    end,
    ok = inet:setopts(Socket, [{active, once}]),
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
handle_info({tcp, _Socket, <<?READ_RADIO_PACKET,
                             IV:12/binary,
                             OnionCompactKey:32/binary,
                             Tag:4/binary,
                             CipherText/binary>>},
            #state{privkey=PrivKey, socket=Socket}=State) ->
    AAD = <<IV/binary, OnionCompactKey/binary>>,
    PubKey = ecc_compact:recover_key(OnionCompactKey),
    SharedKey = public_key:compute_key(element(1, PubKey), PrivKey),
    case crypto:block_decrypt(aes_gcm, SharedKey, IV, {AAD, CipherText, Tag}) of
        error ->
            lager:error("Could not decrypt");
        <<Size:8/integer-unsigned, Data:Size/binary, InnerLayer/binary>> ->
            lager:info("Decrypted a layer: ~p~n", [Data]),
            _ = erlang:spawn(?MODULE, send_receipt, [IV, Data]),
            gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET, AAD/binary, InnerLayer/binary>>)
    end,
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
    %% make up some random data so nobody can tell if they're the last link in the chain
    crypto:strong_rand_bytes(20);
construct_onion([{Data, PubKey} | Tail], PvtOnionKey, OnionCompactKey, IV) ->
    SecretKey = public_key:compute_key(element(1, ecc_compact:recover_key(PubKey)), PvtOnionKey),
    InnerLayer = construct_onion(Tail, PvtOnionKey, OnionCompactKey, IV),
    {CipherText, Tag} = crypto:block_encrypt(aes_gcm,
                                             SecretKey,
                                             IV, {<<IV/binary, OnionCompactKey/binary>>,
                                                  <<(byte_size(Data)):8/integer, Data/binary, InnerLayer/binary>>, 4}),
    <<Tag:4/binary, CipherText/binary>>.