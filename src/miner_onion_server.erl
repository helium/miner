%%%-------------------------------------------------------------------
%% @doc miner_onion_server
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_server).

-behavior(gen_server).

-record(state,
        {socket :: gen_tcp:socket(),
         compact_key :: ecc_compact:compact_key(),
         privkey,
         sender :: undefined | {pid(), term()},
         controlling_process :: pid()
        }).

-export([start_link/5]).
-export([send/1, construct_onion/1, socket/0, compact_key/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(WRITE_RADIO_PACKET, 16#0).
-define(WRITE_RADIO_PACKET_ACK, 16#80).
-define(READ_RADIO_PACKET, 16#81).

%% ==================================================================
%% API calls
%% ==================================================================
start_link(Host, Port, CompactKey, PrivateKey, ControllingProcess) ->
    lager:debug("Host: ~p, Port: ~p", [Host, Port]),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Host, Port, CompactKey, PrivateKey, ControllingProcess], []).

init([Host, Port, CompactKey, PrivateKey, ControllingProcess]) ->
    lager:debug("CompactKey: ~p", [CompactKey]),
    {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, 2}, {active, once}, {nodelay, true}]),
    {ok, #state{socket=Socket, compact_key=CompactKey, privkey=PrivateKey, controlling_process=ControllingProcess}}.

-spec send(binary()) -> ok.
send(Data) ->
    gen_server:call(?MODULE, {send, Data}).

-spec socket() -> {ok, gen_tcp:socket()}.
socket() ->
    gen_server:call(?MODULE, socket).

-spec compact_key() -> {ok, ecc_compact:compact_key()}.
compact_key() ->
    gen_server:call(?MODULE, compact_key).

%% ==================================================================
%% gen_server handle_calls
%% ==================================================================
handle_call({send, Data}, From, State=#state{socket=Socket}) when Socket /= undefined ->
    ok = gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET, Data/binary>>),
    {noreply, State#state{sender=From}};
handle_call(socket, _From, State=#state{socket=Socket}) when Socket /= undefined ->
    {reply, {ok, Socket}, State};
handle_call(compact_key, _From, State=#state{compact_key=CK}) when CK /= undefined ->
    {reply, {ok, CK}, State};

%% ==================================================================
%% gen_server fallback call
%% ==================================================================
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%% ==================================================================
%% gen_server fallback cast
%% ==================================================================
handle_cast(_Msg, State) ->
    {noreply, State}.

%% ==================================================================
%% gen_server info callbacks
%% ==================================================================

%% handle info received from radio
handle_info({tcp, _Socket, <<?READ_RADIO_PACKET,
                             IV:12/binary,
                             OnionCompactKey:32/binary,
                             Tag:4/binary,
                             CipherText/binary>>},
            State=#state{privkey=PrivKey, socket=Socket}) ->
    AAD = <<IV/binary, OnionCompactKey/binary>>,
    PubKey = ecc_compact:recover_key(OnionCompactKey),
    SharedKey = public_key:compute_key(element(1, PubKey), PrivKey),
    case crypto:block_decrypt(aes_gcm, SharedKey, IV, {AAD, CipherText, Tag}) of
        error ->
            lager:error("Could not decrypt");
        <<Size:8/integer-unsigned, Data:Size/binary, InnerLayer/binary>> ->
            lager:info("Decrypted a layer: ~p~n", [Data]),
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
    timer:sleep(timer:seconds(5)),
    {stop, normal, State};
handle_info({tcp_error, _Socket, Reason}, State) ->
    lager:error("tcp_error, reason: ~p", [Reason]),
    timer:sleep(timer:seconds(5)),
    {stop, normal, State};

%% ==================================================================
%% gen_server fallback handle_info
%% ==================================================================
handle_info(_Msg, State) ->
    lager:warning("unhandled Msg: ~p", [_Msg]),
    {noreply, State}.

%% ==================================================================
%% internal functions
%% ==================================================================
-spec construct_onion([{binary(), ecc_compact:compact_key()}]) -> binary().
construct_onion(DataAndPubkeys) ->
    {ok, PvtOnionKey, OnionCompactKey} = ecc_compact:generate_key(),
    IV = crypto:strong_rand_bytes(12),
    <<IV/binary, OnionCompactKey/binary, (construct_onion(DataAndPubkeys, PvtOnionKey, OnionCompactKey, IV))/binary>>.

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
