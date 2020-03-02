-module(miner_lora).

-behaviour(gen_server).

-export([
    start_link/1,
    send/1,
    send_poc/5
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include("lora.hrl").

-record(gateway, {
    mac,
    ip,
    port,
    sent =0,
    received = 0,
    dropped = 0,
    status,
    rtt_samples = [],
    rtt=5000000 %% in microseconds
}).

-record(state, {
    socket,
    gateways = #{}, %% keyed by MAC
    packet_timers = #{}, %% keyed by token
    sig_fun,
    pubkey_bin
}).

-type state() :: #state{}.
-type gateway() :: #gateway{}.
-type helium_packet() :: #packet_pb{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

-spec send(helium_packet()) -> ok | {error, any()}.
send(#packet_pb{payload=Payload, timestamp=When, signal_strength=Power, frequency=Freq, datarate=DataRate}) ->
    gen_server:call(?MODULE, {send, Payload, When, Freq, DataRate, Power, true}, 11000).

-spec send_poc(binary(), any(), float(), iolist(), any()) -> ok | {error, any()}.
send_poc(Payload, When, Freq, DataRate, Power) ->
    gen_server:call(?MODULE, {send, Payload, When, Freq, DataRate, Power, false}, 11000).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPPort = maps:get(radio_udp_bind_port, Args),
    {ok, Socket} = gen_udp:open(UDPPort, [binary, {active, 100}, {ip, UDPIP}]),
    {ok, #state{socket=Socket,
                sig_fun = maps:get(sig_fun, Args),
                pubkey_bin = blockchain_swarm:pubkey_bin()}}.

handle_call({send, Payload, When, Freq, DataRate, Power, IPol}, From, #state{socket=Socket,
                                                                       gateways=Gateways,
                                                                       packet_timers=Timers}=State) ->
    Token = mk_token(Timers),
    %% TODO we should check this for regulatory compliance
    BinJSX = jsx:encode(
        #{<<"txpk">> => #{
            %% IPol for downlink to devices only, not poc packets
            <<"ipol">> => IPol,
            <<"imme">> => When == immediate,
            <<"powe">> => trunc(Power),
            %% TODO gps time?
            <<"tmst">> => When,
            <<"freq">> => Freq,
            <<"modu">> => <<"LORA">>,
            <<"datr">> => list_to_binary(DataRate),
            <<"codr">> => <<"4/5">>,
            <<"size">> => byte_size(Payload),
            <<"rfch">> => 0,
            <<"data">> => base64:encode(Payload)
        }
    }),
    #gateway{ip=IP, port=Port} = select_gateway(Gateways),
    Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>,
    ok = gen_udp:send(Socket, IP, Port, Packet),
    %% TODO a better timeout would be good here
    Ref = erlang:send_after(10000, self(), {tx_timeout, Token}),
    {noreply, State#state{packet_timers=maps:put(Token, {send, Ref, From}, Timers)}};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({tx_timeout, Token}, #state{packet_timers=Timers}=State) ->
    case maps:find(Token, Timers) of
        {ok, {send, _Ref, From}} ->
            gen_server:reply(From, {error, timeout});
        error ->
            ok
    end,
    {noreply, State#state{packet_timers=maps:remove(Token, Timers)}};
handle_info({udp, Socket, IP, Port, Packet}, #state{socket=Socket}=State) ->
    State2 = handle_udp_packet(Packet, IP, Port, State),
    {noreply, State2};
handle_info({udp_passive, Socket}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, 100}]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{socket=Socket}) ->
    gen_udp:close(Socket),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec mk_token(map()) -> binary().
mk_token(Timers) ->
    Token = <<(rand:uniform(65535)):16/integer-unsigned-little>>,
    case maps:is_key(Token, Timers) of
        true -> mk_token(Timers);
        false -> Token
    end.

-spec select_gateway(map()) -> gateway().
select_gateway(Gateways) ->
    erlang:element(2, erlang:hd(maps:to_list(Gateways))).

-spec handle_udp_packet(binary(), inet:ip_address(), inet:port_number(), state()) -> state().
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PUSH_DATA:8/integer-unsigned,
                    MAC:64/integer,
                    JSON/binary>>, IP, Port, #state{socket=Socket, gateways=Gateways}=State) ->
    lager:info("PUSH_DATA ~p from ~p on ~p", [jsx:decode(JSON), MAC, Port]),
    Gateway =
        case maps:find(MAC, Gateways) of
            {ok, #gateway{received=Received}=G} ->
                G#gateway{ip=IP, port=Port, received=Received+1};
            error ->
                #gateway{mac=MAC, ip=IP, port=Port, received=1}
        end,
    ok = gen_udp:send(Socket, IP, Port, <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_ACK:8/integer-unsigned>>),
    handle_json_data(jsx:decode(JSON), Gateway, State);
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PULL_DATA:8/integer-unsigned,
                    MAC:64/integer>>, IP, Port, #state{socket=Socket, gateways=Gateways}=State) ->
    ok = gen_udp:send(Socket, IP, Port, <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_ACK:8/integer-unsigned>>),
    lager:info("PULL_DATA from ~p on ~p", [MAC, Port]),
    Gateway =
        case maps:find(MAC, Gateways) of
            {ok, #gateway{received=Received}=G} ->
                G#gateway{ip=IP, port=Port, received=Received+1};
            error ->
                #gateway{mac=MAC, ip=IP, port=Port, received=1}
        end,
    State#state{gateways=maps:put(MAC, Gateway, Gateways)};
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?TX_ACK:8/integer-unsigned,
                    _MAC:64/integer,
                    MaybeJSON/binary>>, _IP, _Port, #state{packet_timers=Timers}=State) ->
    lager:info("TX ack for token ~p ~p", [Token, MaybeJSON]),
    case maps:find(Token, Timers) of
        {ok, {send, Ref, From}} when MaybeJSON == <<>> -> %% empty string means success, at least with the semtech reference implementation
            _ = erlang:cancel_timer(Ref),
            _ = gen_server:reply(From, ok),
            State#state{packet_timers=maps:remove(Token, Timers)};
        {ok, {send, Ref, From}} ->
            %% likely some kind of error here
            _ = erlang:cancel_timer(Ref),
            Reply = case kvc:path([<<"txpk_ack">>, <<"error">>], jsx:decode(MaybeJSON)) of
                <<"NONE">> ->
                    lager:info("packet sent ok"),
                    ok;
                <<"COLLISION_", _/binary>> ->
                    %% colliding with a beacon or another packet, check if join2/rx2 is OK
                    lager:info("collision"),
                    {error, collision};
                <<"TOO_LATE">> ->
                    lager:info("too late"),
                    {error, too_late};
                <<"TOO_EARLY">> ->
                    lager:info("too early"),
                    {error, too_early};
                <<"TX_FREQ">> ->
                    lager:info("tx frequency not supported"),
                    {error, bad_tx_frequency};
                <<"TX_POWER">> ->
                    lager:info("tx power not supported"),
                    {error, bad_tx_power};
                <<"GPL_UNLOCKED">> ->
                    lager:info("transmitting on GPS time not supported because no GPS lock"),
                    {error, no_gps_lock};
                Error ->
                    %% any other errors are pretty severe
                    lager:error("Failure enqueing packet for gateway ~p", [Error]),
                    {error, {unknown, Error}}
            end,
            gen_server:reply(From, Reply),
            State#state{packet_timers=maps:remove(Token, Timers)};
        error ->
            State
    end;
handle_udp_packet(Packet, _IP, _Port, State) ->
    lager:info("unhandled udp packet ~p", [Packet]),
    State.

-spec handle_json_data(list(), gateway(), state()) -> state().
handle_json_data([], _Gateway, State) ->
    State;
handle_json_data([{<<"rxpk">>, Packets}|Tail], Gateway, State0) ->
    State1 = handle_packets(sort_packets(Packets), Gateway, State0),
    handle_json_data(Tail, Gateway, State1);
handle_json_data([{<<"stat">>, Status}|Tail], Gateway0, #state{gateways=Gateways}=State) ->
    Gateway1 = Gateway0#gateway{status=Status},
    lager:info("got status ~p", [Status]),
    lager:info("Gateway ~p", [lager:pr(Gateway1, ?MODULE)]),
    Mac = Gateway1#gateway.mac,
    handle_json_data(Tail, Gateway1, State#state{gateways=maps:put(Mac, Gateway1, Gateways)}).

-spec sort_packets(list()) -> list().
sort_packets(Packets) ->
    lists:sort(
        fun(A, B) ->
            proplists:get_value(<<"lsnr">>, A) >= proplists:get_value(<<"lsnr">>, B)
        end,
        Packets
    ).

-spec handle_packets(list(), gateway(), state()) -> state().
handle_packets([], _Gateway, State) ->
    State;
handle_packets([Packet|Tail], Gateway, #state{pubkey_bin=PubKeyBin, sig_fun=SigFun}=State) ->
    Data = base64:decode(proplists:get_value(<<"data">>, Packet)),
    case route(Data) of
        error ->
            ok;
        {onion, Payload} ->
            %% onion server
            miner_onion_server:decrypt_radio(
                Payload,
                erlang:trunc(proplists:get_value(<<"rssi">>, Packet)),
                proplists:get_value(<<"lsnr">>, Packet),
                %% TODO we might want to send GPS time here, if available
                proplists:get_value(<<"tmst">>, Packet),
                proplists:get_value(<<"freq">>, Packet),
                proplists:get_value(<<"datr">>, Packet)
            );
        {Type, OUI} ->
            lager:notice("Routing ~p", [OUI]),
            erlang:spawn(fun() -> send_to_router(PubKeyBin, SigFun, {Type, OUI, Packet}) end)
    end,
    handle_packets(Tail, Gateway, State).

-spec route(binary()) -> any().
route(Pkt) ->
    case longfi:deserialize(Pkt) of
        error ->
            route_non_longfi(Pkt);
        {ok, LongFiPkt} ->
            %% hello longfi, my old friend
            try longfi:type(LongFiPkt) == monolithic andalso longfi:oui(LongFiPkt) == 0 andalso longfi:device_id(LongFiPkt) == 1 of
                true ->
                    {onion, longfi:payload(LongFiPkt)};
                false ->
                    {longfi, longfi:oui(LongFiPkt)}
            catch _:_ ->
                      route_non_longfi(Pkt)
            end
    end.

% Some binary madness going on here
-spec route_non_longfi(binary()) -> any().
route_non_longfi(<<?JOIN_REQUEST:3, _:5, AppEUI0:8/binary, _DevEUI0:8/binary, _DevNonce:2/binary, _MIC:4/binary>>) ->
    <<OUI:32/integer-unsigned-big, _DID:32/integer-unsigned-big>> = reverse(AppEUI0),
    {lorawan, OUI};
route_non_longfi(<<MType:3, _:5,DevAddr0:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1, FOptsLen:4,
                   _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary, PayloadAndMIC/binary>>) when MType == ?UNCONFIRMED_UP; MType == ?CONFIRMED_UP ->
    Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) -4}),
    {FPort, _FRMPayload} =
        case Body of
            <<>> -> {undefined, <<>>};
            <<Port:8, Payload/binary>> -> {Port, Payload}
        end,
    case FPort of
        0 when FOptsLen /= 0 ->
            error;
        _ ->
            <<OUI:32/integer-unsigned-big>> = DevAddr0,
            {lorawan, OUI}
    end;
route_non_longfi(_) ->
    error.

-spec reverse(binary()) -> binary().
reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

-spec send_to_router(libp2p_crypto:pubkey_bin(), function(), any()) -> ok.
send_to_router(PubkeyBin, SigFun, {Type, OUI, Packet}) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("ingnored packet chain is undefined");
        Chain ->
            Data = base64:decode(proplists:get_value(<<"data">>, Packet)),
            Ledger = blockchain:ledger(Chain),
            Swarm = blockchain_swarm:swarm(),
            RSSI = proplists:get_value(<<"rssi">>, Packet),
            SNR = proplists:get_value(<<"lsnr">>, Packet),
            %% TODO we might want to send GPS time here, if available
            Time = proplists:get_value(<<"tmst">>, Packet),
            Freq = proplists:get_value(<<"freq">>, Packet),
            DataRate = proplists:get_value(<<"datr">>, Packet),
            HeliumPacket = #packet_pb{
                oui = OUI,
                type = Type,
                payload = Data,
                timestamp = Time,
                signal_strength = RSSI,
                frequency = Freq,
                snr = SNR,
                datarate = DataRate
            },
            PbPacket = #blockchain_state_channel_packet_v1_pb{
                packet = HeliumPacket,
                hotspot = PubkeyBin
            },
            %% TODO we probably need an ephemeral key for the state channel to take the load off the ECC
            Sig = SigFun(blockchain_state_channel_v1_pb:encode_msg(PbPacket)),
            SignedPBPacket = PbPacket#blockchain_state_channel_packet_v1_pb{signature=Sig},
            StateChannelMsg = blockchain_state_channel_v1_pb:encode_msg(#blockchain_state_channel_message_v1_pb{msg={packet, SignedPBPacket}}),
            case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                {error, _Reason} ->
                    case OUI of
                        1 ->
                            case application:get_env(miner, oui1_router, undefined) of
                                undefined ->
                                    lager:warning("ingnored could not find OUI ~p in ledger and no oui1 router is set", [OUI]);
                                Address ->
                                    send_to_router_(Swarm, Address, StateChannelMsg)
                            end;
                        _ ->
                            case application:get_env(miner, default_router, undefined) of
                                undefined ->
                                    lager:warning("ingnored could not find OUI ~p in ledger and no default router is set", [OUI]);
                                Address ->
                                    send_to_router_(Swarm, Address, StateChannelMsg)
                            end
                    end;
                {ok, Routing} ->
                    Addresses = blockchain_ledger_routing_v1:addresses(Routing),
                    lager:debug("found addresses ~p", [Addresses]),
                    lists:foreach(
                        fun(BinAddress) ->
                            Address = erlang:binary_to_list(BinAddress),
                            send_to_router_(Swarm, Address, StateChannelMsg)
                        end,
                        Addresses
                    )
            end
    end.

-spec send_to_router_(pid(), string(), binary()) -> ok.
send_to_router_(Swarm, Address, Packet) ->
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

