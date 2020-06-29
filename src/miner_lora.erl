-module(miner_lora).

-behaviour(gen_server).

-export([
    start_link/1,
    handle_response/1,
    send/1,
    send_poc/5,
    port/0,
    position/0,
    location_ok/0,
    reg_domain_data_for_addr/2,
    reg_domain_data_for_countrycode/1,
    region/0
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
    pubkey_bin,
    mirror_socket,
    latlong,
    reg_domain_confirmed = false :: boolean(),
    reg_region :: atom(),
    reg_freq_list :: [float()]
}).

-record(country, {
    short_code::binary(),
    lat::binary(),
    long::binary(),
    name::binary(),
    region::atom(),
    geo_zone::atom()
}).

-type state() :: #state{}.
-type gateway() :: #gateway{}.
-type helium_packet() :: #packet_pb{}.
-type freq_data() :: {Region::atom(), Freqs::[float]}.

-define(COUNTRY_FREQ_DATA, country_freq_data).

%% in meters
-define(MAX_WANDER_DIST, 200).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% @doc used to handle state channel responses
-spec handle_response(blockchain_state_channel_response_v1:response()) -> ok | {error, any()}.
handle_response(Resp) ->
    case blockchain_state_channel_response_v1:downlink(Resp) of
        undefined ->
            ok;
        Packet ->
            send(Packet)
    end.

-spec send(helium_packet()) -> ok | {error, any()}.
send(#packet_pb{payload=Payload, frequency=Freq, timestamp=When, signal_strength=Power, datarate=DataRate} = Packet) ->
    lager:debug("got download packet ~p via freq ~p", [Packet, Freq]),
    %% this is used for downlink packets that have been assigned a downlink frequency by the router, so just use the supplied frequency
    ChannelSelectorFun = fun(_FreqList) -> Freq end,
    gen_server:call(?MODULE, {send, Payload, When, ChannelSelectorFun, DataRate, Power, true}, 11000).

-spec send_poc(binary(), any(), function(), iolist(), any()) -> ok | {error, any()}.
send_poc(Payload, When, ChannelSelectorFun, DataRate, Power) ->
    gen_server:call(?MODULE, {send, Payload, When, ChannelSelectorFun, DataRate, Power, false}, 11000).

-spec port() -> {ok, inet:port_number()} | {error, any()}.
port() ->
    gen_server:call(?MODULE, port, 11000).

-spec position() -> {ok, {float(), float()}} |
                    {ok, bad_assert, {float(), float()}} |
                    {error, any()}.
position() ->
    try
        gen_server:call(?MODULE, position, infinity)
    catch _:_ ->
            {error, no_fix}
    end.

-spec location_ok() -> true | false.
location_ok() ->
    %% the below code is tested and working.  we're going to roll
    %% out the metadata update so app users can see their status
    %% case position() of
    %%     {error, _Error} ->
    %%         lager:debug("pos err ~p", [_Error]),
    %%         false;
    %%     {ok, _} ->
    %%         true;
    %%     %% fix but too far from assert
    %%     {ok, _, _} ->
    %%         false
    %% end.

    %% this terrible thing is to fake out dialyzer
    application:get_env(miner, loc_ok_default, true).

-spec reg_domain_data_for_addr(undefined | blockchain:blockchain(), libp2p_crypto:pubkey_bin())-> {error, any()} | {ok, freq_data()}.
reg_domain_data_for_addr(Chain, Addr)->
    Ledger = blockchain:ledger(Chain),
    {ok, Gw} = blockchain_ledger_v1:find_gateway_info(Addr, Ledger),
    %% check if the miner has asserted its location, if not we will try other methods to determine this
    case blockchain_ledger_gateway_v2:location(Gw) of
        undefined ->
            {error, location_not_asserted};
        _H3Location ->
            %% location has been asserted, we can proceed...
            case country_code_for_addr(Addr) of
                {ok, CC} ->
                    %% use country code to get regulatory domain data
                    ?MODULE:reg_domain_data_for_countrycode(CC);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec reg_domain_data_for_countrycode(binary()) -> {ok, freq_data() | {error, any()}}.
reg_domain_data_for_countrycode(CC)->
    case ets:lookup(?COUNTRY_FREQ_DATA, CC) of
        [{_Key, Res}] ->
            lager:debug("found countrycode data ~p", [Res]),
            FreqMap = application:get_env(miner, frequency_data, #{}),
            freq_data(Res, FreqMap);
        _ ->
            lager:warning("Country code ~p not found",[CC]),
            {error, countrycode_not_found}
    end.

-spec region() -> {ok, atom()}.
region()->
    gen_server:call(?MODULE, region, 5000).


%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    lager:info("init with args ~p", [Args]),
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPPort = maps:get(radio_udp_bind_port, Args),
    {ok, Socket} = gen_udp:open(UDPPort, [binary, {reuseaddr, true}, {active, 100}, {ip, UDPIP}]),
    MirrorSocket = case application:get_env(miner, radio_mirror_port, undefined) of
        undefined ->
            undefined;
        P ->
            {ok, S} = gen_udp:open(P, [binary, {active, true}]),
            S
    end,

    %% cloud/miner pro will never assert location and so we dont  use regulatory domain checks for these miners
    %% instead they will supply a region value, use this if it exists
    {RegDomainConfirmed, DefaultRegRegion, DefaultRegFreqList} =
        case maps:get(region_override, Args, undefined) of
            undefined ->
                %% not overriding domain checks, so initialize with source data and defaults
                ets:new(?COUNTRY_FREQ_DATA, [named_table, public]),
                ok = init_ets(),
                erlang:send_after(5000, self(), reg_domain_timeout),
                {false, undefined, undefined};
            Region ->
                lager:info("using region specifed in config: ~p", [Region]),
                %% get the freq map from config and use Region to get our required data
                FreqMap = application:get_env(miner, frequency_data, #{}),
                case maps:get(Region, FreqMap, undefined) of
                    undefined ->
                        lager:warning("specified region ~p not supported", [Region]),
                        {false, undefined, undefined};
                    FreqList ->
                        lager:info("using freq list ~p", [FreqList]),
                        {true, Region, FreqList}
                end
        end,
    {ok, #state{socket=Socket,
                sig_fun = maps:get(sig_fun, Args),
                mirror_socket = {MirrorSocket, undefined},
                pubkey_bin = blockchain_swarm:pubkey_bin(),
                reg_domain_confirmed = RegDomainConfirmed,
                reg_region = DefaultRegRegion,
                reg_freq_list = DefaultRegFreqList}}.

handle_call({send, _Payload, _When, _ChannelSelectorFun, _DataRate, _Power, _IPol}, _From,
                #state{reg_domain_confirmed = false}=State) ->
    lager:debug("ignoring send request as regulatory domain not yet confirmed", []),
    {reply, {error, reg_domain_unconfirmed}, State};
handle_call({send, Payload, When, ChannelSelectorFun, DataRate, Power, IPol}, From,
                #state{ socket=Socket,
                        gateways=Gateways,
                        packet_timers=Timers,
                        reg_freq_list = Freqs}=State) ->
    case select_gateway(Gateways) of
        {error, _}=Error ->
            {reply, Error, State};
        {ok, #gateway{ip=IP, port=Port}} ->
            %% the fun is set by the sender and is used to deterministically route data via channels
            LocalFreq = ChannelSelectorFun(Freqs),
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
                             <<"freq">> => LocalFreq,
                             <<"modu">> => <<"LORA">>,
                             <<"datr">> => list_to_binary(DataRate),
                             <<"codr">> => <<"4/5">>,
                             <<"size">> => byte_size(Payload),
                             <<"rfch">> => 0,
                             <<"data">> => base64:encode(Payload)
                            }
                        }),
            Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>,
            maybe_mirror(State#state.mirror_socket, Packet),
            lager:debug("sending packet via channel: ~p",[LocalFreq]),
            ok = gen_udp:send(Socket, IP, Port, Packet),
            %% TODO a better timeout would be good here
            Ref = erlang:send_after(10000, self(), {tx_timeout, Token}),
            {noreply, State#state{packet_timers=maps:put(Token, {send, Ref, From}, Timers)}}
    end;
handle_call(port, _From, State) ->
    {reply, inet:port(State#state.socket), State};
handle_call(position, _From, #state{latlong = undefined} = State) ->
    {reply, {error, no_fix}, State};
handle_call(position, _From, #state{pubkey_bin = Addr} = State) ->
    try
        Chain = blockchain_worker:blockchain(),
        Ledger = blockchain:ledger(Chain),
        {ok, Gw} = blockchain_ledger_v1:find_gateway_info(Addr, Ledger),
        Ret =
            case blockchain_ledger_gateway_v2:location(Gw) of
                undefined ->
                    {error, not_asserted};
                H3Loc ->
                    case vincenty:distance(h3:to_geo(H3Loc), State#state.latlong) of
                        {error, _E} ->
                            lager:debug("fix error! ~p", [_E]),
                            {error, bad_calculation};
                        {ok, Distance} when (Distance * 1000) > ?MAX_WANDER_DIST ->
                            lager:debug("fix too far! ~p", [Distance]),
                            {ok, bad_assert, State#state.latlong};
                        {ok, _D} ->
                            lager:debug("fix good! ~p", [_D]),
                            {ok, State#state.latlong}
                    end
            end,
        {reply, Ret, State}
    catch C:E:S ->
            lager:warning("error trying to get position: ~p:~p ~p",
                          [C, E, S]),
        {reply, {error, position_calc_error}, State}
    end;
handle_call(region, _From, #state{reg_region = Region} = State) ->
    {reply, {ok, Region}, State};

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(reg_domain_timeout, #state{reg_domain_confirmed=false, pubkey_bin=Addr} = State) ->
    lager:debug("checking regulatory domain for address ~p", [Addr]),
    %% dont crash if any of this goes wrong, just try again in a bit
    try
        Chain = blockchain_worker:blockchain(),
        case ?MODULE:reg_domain_data_for_addr(Chain, Addr) of
            {error, Reason}->
                lager:debug("cannot confirm regulatory domain for miner ~p, reason: ~p", [Reason]),
                %% the hotspot has not yet asserted its location, transmits will remain disabled
                %% we will check again after a period
                erlang:send_after(30000, self(), reg_domain_timeout),
                {noreply, State};
            {ok, {Region, FrequencyList}} ->
                lager:info("confirmed regulatory domain for miner ~p.  region: ~p, freqlist: ~p",
                    [Addr, Region, FrequencyList]),
                {noreply, State#state{ reg_domain_confirmed = true, reg_region = Region,
                        reg_freq_list = FrequencyList}}
        end
    catch
        _Type:Exception ->
            lager:warning("error whilst checking regulatory domain: ~p.  Will try again...",[Exception]),
            erlang:send_after(30000, self(), reg_domain_timeout),
            {noreply, State}
    end;
handle_info({tx_timeout, Token}, #state{packet_timers=Timers}=State) ->
    case maps:find(Token, Timers) of
        {ok, {send, _Ref, From}} ->
            gen_server:reply(From, {error, timeout});
        error ->
            ok
    end,
    {noreply, State#state{packet_timers=maps:remove(Token, Timers)}};
handle_info({udp, Socket, IP, Port, Packet}, #state{socket=Socket}=State) ->
    maybe_mirror(State#state.mirror_socket, Packet),
    State2 = handle_udp_packet(Packet, IP, Port, State),
    {noreply, State2};
handle_info({udp_passive, Socket}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, 100}]),
    {noreply, State};
handle_info({udp, Socket, IP, Port, _Packet}, #state{mirror_socket={Socket, _}}=State) ->
    lager:info("received mirror port connection from ~p ~p", [IP, Port]),
    {noreply, State#state{mirror_socket={Socket, {IP, Port}}}};
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
                    JSON/binary>>, IP, Port, #state{socket=Socket, gateways=Gateways,
                                                    reg_domain_confirmed = RegDomainConfirmed}=State) ->
    lager:info("PUSH_DATA ~p from ~p on ~p", [jsx:decode(JSON), MAC, Port]),
    Gateway =
        case maps:find(MAC, Gateways) of
            {ok, #gateway{received=Received}=G} ->
                G#gateway{ip=IP, port=Port, received=Received+1};
            error ->
                #gateway{mac=MAC, ip=IP, port=Port, received=1}
        end,
    Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_ACK:8/integer-unsigned>>,
    maybe_mirror(State#state.mirror_socket, Packet),
    maybe_send_udp_ack(Socket, IP, Port, Packet, RegDomainConfirmed),
    handle_json_data(jsx:decode(JSON, [return_maps]), Gateway, State);
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PULL_DATA:8/integer-unsigned,
                    MAC:64/integer>>, IP, Port, #state{socket=Socket, gateways=Gateways,
                                                        reg_domain_confirmed = RegDomainConfirmed}=State) ->
    Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_ACK:8/integer-unsigned>>,
    maybe_mirror(State#state.mirror_socket, Packet),
    maybe_send_udp_ack(Socket, IP, Port, Packet, RegDomainConfirmed),
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
    Mac = Gateway1#gateway.mac,
    State1 = maybe_update_gps(Status, State),
    handle_json_data(maps:remove(<<"stat">>, Map), Gateway1,
                     State1#state{gateways=maps:put(Mac, Gateway1, Gateways)});
handle_json_data(_, _Gateway, State) ->
    State.

%% cache GPS the state with each update.  I'm not sure if this will
%% lead to a lot of wander, but I do want to be able to refine if we
%% have a poor quality initial lock.  we might want to keep track of
%% server boot time and lock it down after some period of time.
-spec maybe_update_gps(#{}, state()) -> state().
maybe_update_gps(#{<<"lati">> := Lat, <<"long">> := Long}, State) ->
    State#state{latlong = {Lat, Long}};
maybe_update_gps(_Status, State) ->
    State.
maybe_send_udp_ack(_Socket, _IP, _Port, _Packet, false = _RegDomainConfirmed)->
    ok;
maybe_send_udp_ack(Socket, IP, Port, Packet, _RegDomainConfirmed)->
    ok = gen_udp:send(Socket, IP, Port, Packet).

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
handle_packets(_Packets, _Gateway, #state{reg_domain_confirmed = false} = State) ->
    State;
handle_packets([Packet|Tail], Gateway, #state{reg_region = Region} = State) ->
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
        {Type, RoutingInfo} ->
            lager:notice("Routing ~p", [RoutingInfo]),
            erlang:spawn(fun() -> send_to_router(Type, RoutingInfo, Packet, Region) end)
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
route_non_longfi(<<?JOIN_REQUEST:3, _:5, AppEUI:64/integer-unsigned-little, DevEUI:64/integer-unsigned-little, _DevNonce:2/binary, _MIC:4/binary>>) ->
    {lorawan, {eui, DevEUI, AppEUI}};
route_non_longfi(<<MType:3, _:5, DevAddr:32/integer-unsigned-little, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1, FOptsLen:4,
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
            {lorawan, {devaddr, DevAddr}}
    end;
route_non_longfi(_) ->
    error.

maybe_mirror({undefined, undefined}, _) ->
    ok;
maybe_mirror({_, undefined}, _) ->
    ok;
maybe_mirror({Sock, Destination}, Packet) ->
    gen_udp:send(Sock, Destination, Packet).

-spec send_to_router(lorawan, blockchain_helium_packet:routing_info(), map(), atom()) -> ok.
send_to_router(Type, RoutingInfo, Packet, Region) ->
    Data = base64:decode(maps:get(<<"data">>, Packet)),
    RSSI = maps:get(<<"rssi">>, Packet),
    SNR = maps:get(<<"lsnr">>, Packet),
    %% TODO we might want to send GPS time here, if available
    Time = maps:get(<<"tmst">>, Packet),
    Freq = maps:get(<<"freq">>, Packet),
    DataRate = maps:get(<<"datr">>, Packet),
    HeliumPacket = blockchain_helium_packet_v1:new(RoutingInfo, Type, Data, Time, RSSI, Freq, DataRate, SNR),
    blockchain_state_channels_client:packet(HeliumPacket, application:get_env(miner, default_routers, []), Region).

-spec country_code_for_addr(libp2p_crypto:pubkey_bin()) -> {ok, binary()} | {error, failed_to_find_geodata_for_addr}.
country_code_for_addr(Addr)->
    B58Addr = libp2p_crypto:bin_to_b58(Addr),
    URL = "https://api.helium.io/v1/hotspots/" ++ B58Addr,
    case httpc:request(get, {URL, []}, [{timeout, 5000}],[]) of
        {ok, {{_HTTPVersion, 200, _RespBody}, _Headers, JSONBody}} = Resp ->
            lager:debug("hotspot info response: ~p", [Resp]),
            %% body will be a list of geocode info of which one key will be the country code
            Body = jsx:decode(list_to_binary(JSONBody), [return_maps]),
            %% return the country code from the returned response
            CC = maps:get(<<"short_country">>, maps:get(<<"geocode">>, maps:get(<<"data">>, Body)), undefined),
            {ok, CC};
        _ ->
            {error, failed_to_find_geodata_for_addr}
    end.

-spec freq_data(#country{}, map())-> {ok, freq_data()}.
freq_data(#country{region = undefined} = _Country, _FreqMap)->
    {error, region_not_set};
freq_data(#country{region = Region}= _Country, FreqMap)->
    case maps:get(Region, FreqMap, undefined) of
        undefined ->
            lager:warning("frequency data not found for region ~p",[Region]),
            {error, frequency_not_found_for_region};
        F->
            {ok, {Region, F}}
    end.

-spec init_ets() -> ok.
init_ets() ->
    PrivDir = code:priv_dir(miner),
    File = application:get_env(miner, reg_domains_file, "countries_reg_domains.csv"),
    lager:debug("loading csv file from ~p", [PrivDir ++ "/" ++ File]),
    {ok, F} = file:open(PrivDir ++ "/" ++ File, [read, raw, binary, {read_ahead, 8192}]),
    ok = csv_rows_to_ets(F),
    ok = file:close(F).

-spec csv_rows_to_ets(pid())-> ok | {error, any()}.
csv_rows_to_ets(F) ->
  try file:read_line(F) of
    {ok, Line} ->
        CP = binary:compile_pattern([<<$,>>, <<$\n>>]),
        [ShortCode, Lat, Long, Country, Region, GeoZone] = binary:split(Line, CP, [global, trim]),
        Rec = #country{short_code=ShortCode, lat=Lat, long=Long, name=Country,
                        region=binary_to_atom(Region, utf8), geo_zone=binary_to_atom(GeoZone, utf8)},
        ets:insert(?COUNTRY_FREQ_DATA, {ShortCode, Rec}),
        csv_rows_to_ets(F);
    eof ->
        ok
    catch
        error:Reason ->
            lager:warning("failed to read file ~p, error: ~p", [F, Reason]),
            {error, Reason}
  end.
