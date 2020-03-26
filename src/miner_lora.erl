-module(miner_lora).

-behaviour(gen_server).

-export([
    start_link/1,
    send/1,
    send_poc/5,
    port/0
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
    time_source :: undefined | #gps_info_pb{} | #ntp_info_pb{}
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

-spec port() -> {ok, inet:port_number()} | {error, any()}.
port() ->
    gen_server:call(?MODULE, port, 11000).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPPort = maps:get(radio_udp_bind_port, Args),
    {ok, Socket} = gen_udp:open(UDPPort, [binary, {reuseaddr, true}, {active, 100}, {ip, UDPIP}]),
    {ok, #state{socket=Socket,
                sig_fun = maps:get(sig_fun, Args),
                pubkey_bin = blockchain_swarm:pubkey_bin()}}.

handle_call({send, Payload, When, Freq, DataRate, Power, IPol}, From, #state{socket=Socket,
                                                                       gateways=Gateways,
                                                                       packet_timers=Timers}=State) ->
    case select_gateway(Gateways) of
        {error, _}=Error ->
            {reply, Error, State};
        {ok, #gateway{ip=IP, port=Port}} ->
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
            Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>,
            ok = gen_udp:send(Socket, IP, Port, Packet),
            %% TODO a better timeout would be good here
            Ref = erlang:send_after(10000, self(), {tx_timeout, Token}),
            {noreply, State#state{packet_timers=maps:put(Token, {send, Ref, From}, Timers)}}
    end;
handle_call(port, _From, State) ->
    {reply, inet:port(State#state.socket), State};
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

-spec select_gateway(map()) -> {ok, gateway()} | {error, no_gateways}.
select_gateway(Gateways) ->
    %% TODO for a multi-tenant miner we'd have a mapping of swarm keys to
    %% 64-bit packet forwarder IDs and, depending on what swarm key this send
    %% was directed to, we'd select the appropriate gateway from the map.
    case maps:size(Gateways) of
        0 ->
            {error, no_gateways};
        _ ->
            {ok, erlang:element(2, erlang:hd(maps:to_list(Gateways)))}
    end.

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
    handle_json_data(jsx:decode(JSON, [return_maps]), Gateway, State);
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

-spec handle_json_data(map(), gateway(), state()) -> state().
handle_json_data(#{<<"rxpk">> := Packets} = Map, Gateway, State0) ->
    State1 = handle_packets(sort_packets(Packets), Gateway, State0),
    handle_json_data(maps:remove(<<"rxpk">>, Map), Gateway, State1);
handle_json_data(#{<<"stat">> := Status} = Map, Gateway0, #state{gateways=Gateways}=State) ->
    Gateway1 = Gateway0#gateway{status=Status},
    lager:info("got status ~p", [Status]),
    lager:info("Gateway ~p", [lager:pr(Gateway1, ?MODULE)]),
    TimeInfo = case maps:find(<<"tacc">>, Status) of
                   {ok, _} ->
                       %% ok we have GPS information
                       {gps, #gps_info_pb{
                                horizontal_accuracy=maps:get(<<"eha">>, Status),
                                vertical_accuracy=maps:get(<<"eva">>, Status),
                                altitude=maps:get(<<"alti">>, Status),
                                time_accuracy=maps:get(<<"tacc">>, Status)
                               }};
                   error ->
                       %% ok, try to get NTP
                       case parse_ntp_status() of
                           {ok, NTPStatus} ->
                               NStatus = proplists:get_value(status, NTPStatus),
                               {ntp, #ntp_info_pb{
                                        synced = (not lists:member(<<"leap_alarm">>, NStatus)) andalso lists:member(<<"sync_ntp">>, NStatus),
                                        stratum = proplists:get_value(stratum, NTPStatus),
                                        sys_jitter = proplists:get_value(sys_jitter, NTPStatus),
                                        clk_jitter = proplists:get_value(clk_jitter, NTPStatus),
                                        clk_wander = proplists:get_value(clk_wander, NTPStatus),
                                        frequency = proplists:get_value(frequency, NTPStatus)
                                       }};
                           Error ->
                               lager:notice("Unable to get NTP status ~p", [Error]),
                               undefined
                       end
               end,
    Gateway2 = Gateway1#gateway{time_source = TimeInfo},
    Mac = Gateway2#gateway.mac,
    handle_json_data(maps:remove(<<"stat">>, Map), Gateway2, State#state{gateways=maps:put(Mac, Gateway2, Gateways)});
handle_json_data(_, _Gateway, State) ->
    State.

-spec sort_packets(list()) -> list().
sort_packets(Packets) ->
    lists:sort(
        fun(A, B) ->
            maps:get(<<"lsnr">>, A) >= maps:get(<<"lsnr">>, B)
        end,
        Packets
    ).

-spec handle_packets(list(), gateway(), state()) -> state().
handle_packets([], _Gateway, State) ->
    State;
handle_packets([Packet|Tail], Gateway, #state{pubkey_bin=PubKeyBin, sig_fun=SigFun}=State) ->
    Data = base64:decode(maps:get(<<"data">>, Packet)),
    case route(Data) of
        error ->
            ok;
        {onion, Payload} ->
            %% onion server
            miner_onion_server:decrypt_radio(
                Payload,
                erlang:trunc(maps:get(<<"rssi">>, Packet)),
                maps:get(<<"lsnr">>, Packet),
                %% TODO we might want to send GPS time here, if available
                maps:get(<<"tmst">>, Packet),
                maps:get(<<"freq">>, Packet),
                maps:get(<<"datr">>, Packet)
            );
        {Type, OUI} ->
            lager:notice("Routing ~p", [OUI]),
            erlang:spawn(fun() -> send_to_router(PubKeyBin, SigFun, {Type, OUI, Gateway, Packet}) end)
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
                    %% we currently don't expect non-onion packets,
                    %% this is probably a false positive on a LoRaWAN packet
                      route_non_longfi(Pkt)
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
send_to_router(PubkeyBin, SigFun, {Type, OUI, Gateway, Packet}) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("ingnored packet chain is undefined");
        Chain ->
            Data = base64:decode(maps:get(<<"data">>, Packet)),
            Ledger = blockchain:ledger(Chain),
            Swarm = blockchain_swarm:swarm(),
            RSSI = maps:get(<<"rssi">>, Packet),
            SNR = maps:get(<<"lsnr">>, Packet),
            TMST = maps:get(<<"tmst">>, Packet),
            Freq = maps:get(<<"freq">>, Packet),
            DataRate = maps:get(<<"datr">>, Packet),
            Time = case maps:find(<<"time">>, Packet) of
                       {ok, TS} ->
                           {Date, {Hours, Minutes, FractionalSeconds}} = iso8601:parse_exact(TS),
                           %% compute the number of seconds since 1970
                           UnixTime = calendar:datetime_to_gregorian_seconds({Date, {Hours, Minutes, trunc(FractionalSeconds)}}) - 62167219200,
                           %% convert the fractional seconds into nanoseconds
                           NanoSeconds = trunc((FractionalSeconds - trunc(FractionalSeconds)) * 1000000000),
                           %% multiply the unix timestamp by 1 billion and add the nanosecond component on
                           (UnixTime * 1000000000) + NanoSeconds;
                       error ->
                           erlang:system_time(nanosecond)
                   end,
            HeliumPacket = #packet_pb{
                oui = OUI,
                type = Type,
                payload = Data,
                internal_conc_timer = TMST,
                signal_strength = RSSI,
                frequency = Freq,
                snr = SNR,
                datarate = DataRate,
                timestamp = Time,
                time_source = Gateway#gateway.time_source
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
                    case application:get_env(miner, default_router, undefined) of
                        undefined ->
                            lager:warning("ingnored could not find OUI ~p in ledger and no default router is set", [OUI]);
                        Address ->
                            send_to_router_(Swarm, Address, StateChannelMsg)
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


parse_ntp_status() ->
    Output = list_to_binary(os:cmd("ntpq -c rv")),
    parse_ntp_status(Output, []).

parse_ntp_status(<<>>, Acc) ->
    {ok, Acc};
parse_ntp_status(<<"associd=", Output/binary>>, Acc) ->
    [Value, Rest] = binary:split(Output, <<" ">>),
    parse_ntp_status(Rest, [{associd, list_to_integer(binary_to_list(Value))}|Acc]);
parse_ntp_status(<<"status=", Output/binary>>, Acc) ->
    [Status, Rest] = binary:split(Output, <<",\n">>),
    [Status0|Statuses] = binary:split(Status, <<", ">>, [global]),
    [_, Status1] = binary:split(Status0, <<" ">>),
    parse_ntp_status(Rest, [{status, [Status1|Statuses]}|Acc]);
parse_ntp_status(<<"version=\"", Output/binary>>, Acc) ->
    [Version, Rest] = binary:split(Output, [<<"\",\n">>, <<"\", ">>]),
    parse_ntp_status(Rest, [{version, Version}|Acc]);
parse_ntp_status(<<"processor=\"", Output/binary>>, Acc) ->
    parse_ntp_string(processor, Output, Acc);
parse_ntp_status(<<"system=\"", Output/binary>>, Acc) ->
    parse_ntp_string(system, Output, Acc);
parse_ntp_status(<<"leap=", Output/binary>>, Acc) ->
    parse_ntp_integer(leap, Output, 2, Acc);
parse_ntp_status(<<"stratum=", Output/binary>>, Acc) ->
    parse_ntp_integer(stratum, Output, Acc);
parse_ntp_status(<<"precision=", Output/binary>>, Acc) ->
    parse_ntp_integer(precision, Output, Acc);
parse_ntp_status(<<"rootdelay=", Output/binary>>, Acc) ->
    parse_ntp_float(rootdelay, Output, Acc);
parse_ntp_status(<<"rootdisp=", Output/binary>>, Acc) ->
    parse_ntp_float(rootdisp, Output, Acc);
parse_ntp_status(<<"refid=", Output/binary>>, Acc) ->
    [Value, Rest] = binary:split(Output, [<<",\n">>, <<", ">>]),
    parse_ntp_status(Rest, [{refid, Value}|Acc]);
parse_ntp_status(<<"reftime=", Output/binary>>, Acc) ->
    parse_ntp_time(reftime, Output, Acc);
parse_ntp_status(<<"clock=", Output/binary>>, Acc) ->
    parse_ntp_time(clock, Output, Acc);
parse_ntp_status(<<"peer=", Output/binary>>, Acc) ->
    parse_ntp_integer(peer, Output, Acc);
parse_ntp_status(<<"tc=", Output/binary>>, Acc) ->
    parse_ntp_integer(tc, Output, Acc);
parse_ntp_status(<<"mintc=", Output/binary>>, Acc) ->
    parse_ntp_integer(mintc, Output, Acc);
parse_ntp_status(<<"offset=", Output/binary>>, Acc) ->
    parse_ntp_float(offset, Output, Acc);
parse_ntp_status(<<"frequency=", Output/binary>>, Acc) ->
    parse_ntp_float(frequency, Output, Acc);
parse_ntp_status(<<"sys_jitter=", Output/binary>>, Acc) ->
    parse_ntp_float(sys_jitter, Output, Acc);
parse_ntp_status(<<"clk_jitter=", Output/binary>>, Acc) ->
    parse_ntp_float(clk_jitter, Output, Acc);
parse_ntp_status(<<"clk_wander=", Output/binary>>, Acc) ->
    parse_ntp_float(clk_wander, Output, Acc);
parse_ntp_status(Rest, _Acc) ->
    {error, {unexpected_token, Rest}}.

parse_ntp_string(Name, Output, Acc) ->
    [Value, Rest] = binary:split(Output, [<<"\",\n">>, <<"\", ">>]),
    parse_ntp_status(Rest, [{Name, Value}|Acc]).

parse_ntp_integer(Name, Output, Acc) ->
    parse_ntp_integer(Name, Output, 10, Acc).

parse_ntp_integer(Name, Output, Base, Acc) ->
    [Value, Rest] = binary:split(Output, [<<",\n">>, <<", ">>, <<"\n">>]),
    parse_ntp_status(Rest, [{Name, list_to_integer(binary_to_list(Value), Base)}|Acc]).

parse_ntp_float(Name, Output, Acc) ->
    [Value, Rest] = binary:split(Output, [<<",\n">>, <<", ">>, <<"\n">>]),
    parse_ntp_status(Rest, [{Name, list_to_float(binary_to_list(Value))}|Acc]).

parse_ntp_time(_Name, <<"(no time), ", Rest/binary>>, Acc) ->
    parse_ntp_status(Rest, Acc);
parse_ntp_time(_Name, <<"(no time),\n", Rest/binary>>, Acc) ->
    parse_ntp_status(Rest, Acc);
parse_ntp_time(Name, Output, Acc) ->
    [_, Rest0] = binary:split(Output, <<"  ">>),
    [DateTime, Rest1] = re:split(Rest0, <<"[0-9],[ \n]">>, [{parts, 2}]),
    parse_ntp_status(Rest1, [{Name, DateTime}|Acc]).
