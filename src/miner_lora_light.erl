%%%-------------------------------------------------------------------
%% @doc
%% == Miner lora for light gateways ==
%%          no use of chain or ledger
%% @end
%%%-------------------------------------------------------------------
-module(miner_lora_light).

-include("src/grpc/autogen/client/gateway_miner_client_pb.hrl").
-behaviour(gen_server).

-export([
    start_link/1,
    handle_response/1,
    send/1,
    send_poc/5,
    port/0,
    location_ok/0,
    region/0,
    region_params_update/2
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
-include_lib("blockchain/include/blockchain_utils.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

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
    socket = undefined :: undefined | port(),
    gateways = #{}, %% keyed by MAC
    packet_timers = #{}, %% keyed by token
    sig_fun,
    pubkey_bin,
    mirror_socket,
    latlong,
    reg_domain_confirmed = false :: boolean(),
    reg_region :: atom(),
    reg_region_params :: blockchain_region_param_v1:region_param_v1(),
    reg_freq_list :: [float()] | undefined,
    reg_throttle = undefined :: undefined | miner_lora_throttle:handle(),
    last_tmst_us = undefined :: undefined | integer(),  % last concentrator tmst reported by the packet forwarder
    last_mono_us = undefined :: undefined | integer(),  % last local monotonic timestamp taken when packet forwarder reported last tmst
    chain = undefined :: undefined | blockchain:blockchain(),
    radio_udp_bind_ip,
    radio_udp_bind_port,
    cur_poc_challenger_type = undefined :: undefined | validator,
    following_chain = true :: undefined | boolean()
}).

-type state() :: #state{}.
-type gateway() :: #gateway{}.
-type helium_packet() :: #packet_pb{}.

-define(COUNTRY_FREQ_DATA, country_freq_data).

%% in meters
-define(MAX_WANDER_DIST, 200).

%% Maximum `tmst` counter value reported by an SX130x concentrator
%% IC. This is a raw [1] counter value with the following
%% characteristics:
%%
%% - unsigned
%% - counts upwards
%% - 32 bits
%% - increments at 1 MHz
%%
%% [1]: On SX1301 it is a raw value. On SX1302 it is a 32 bit value
%% counting at 32 MHz, but the SX1302 HAL throws away 5 bits to match
%% SX1301's behavior.
%%
%% Equivalent `(2^32)-1`
-define(MAX_TMST_VAL, 4294967295).

-ifdef(TEST).
-export([route/1]).
-define(route(Pkt), ?MODULE:route(Pkt)).
-define(REG_DOMAIN_TIMEOUT, 1000).
-else.
-define(route(Pkt), route(Pkt)).
-define(REG_DOMAIN_TIMEOUT, 30000).
-endif.


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
send(#packet_pb{payload=Payload, frequency=Freq, timestamp=When, signal_strength=Power, datarate=DataRate}=Packet) ->
    lager:debug("got download packet ~p via freq ~p", [Packet, Freq]),
    %% this is used for downlink packets that have been assigned a downlink frequency by the router, so just use the supplied frequency
    ChannelSelectorFun = fun(_FreqList) -> Freq end,
    gen_server:call(?MODULE, {send, Payload, When, ChannelSelectorFun, DataRate, Power, true, Packet}, 11000).

-spec send_poc(binary(), any(), function(), iolist(), any()) -> ok | {error, any()} | {warning, any()}.
send_poc(Payload, When, ChannelSelectorFun, DataRate, Power) ->
    gen_server:call(?MODULE, {send, Payload, When, ChannelSelectorFun, DataRate, Power, false, undefined}, 11000).

-spec port() -> {ok, inet:port_number()} | {error, any()}.
port() ->
    gen_server:call(?MODULE, port, 11000).

-spec location_ok() -> true | false.
location_ok() ->
    %% this terrible thing is to fake out dialyzer
    application:get_env(miner, loc_ok_default, true).

-spec region_params_update(atom(), [blockchain_region_param_v1:region_param_v1()]) -> ok.
region_params_update(Region, RegionParams) ->
    gen_server:cast(?MODULE, {region_params_update, Region, RegionParams}).

-spec region() -> {ok, atom()}.
region()->
    %% TODO: recalc region if hotspot re-asserts
    gen_server:call(?MODULE, region, 5000).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("init with args ~p", [Args]),
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    UDPPort = maps:get(radio_udp_bind_port, Args),
    GatewaysRunChain = application:get_env(miner, gateways_run_chain, true),
    lager:info("gateways_run_chain: ~p", [GatewaysRunChain]),
    S0 = #state{pubkey_bin = blockchain_swarm:pubkey_bin(),
                reg_domain_confirmed = false,
                radio_udp_bind_ip = UDPIP,
                radio_udp_bind_port = UDPPort,
                following_chain = GatewaysRunChain
               },
    erlang:send_after(500, self(), init),
    {ok, S0}.

handle_call({send, _Payload, _When, _ChannelSelectorFun, _DataRate, _Power, _IPol, _HlmPacket}, _From,
            #state{reg_domain_confirmed = false}=State) ->
    lager:debug("ignoring send request as regulatory domain not yet confirmed", []),
    {reply, {error, reg_domain_unconfirmed}, State};
handle_call({send, Payload, When, ChannelSelectorFun, DataRate, Power, IPol, HlmPacket}, From, State) ->
    case send_packet(Payload, When, ChannelSelectorFun, DataRate, Power, IPol, HlmPacket, From, State) of
        {error, _}=Error -> {reply, Error, State};
        {ok, State1} -> {noreply, State1}
    end;
handle_call(port, _From, State = #state{socket = undefined}) ->
    {reply, {error, no_socket}, State};
handle_call(port, _From, State) ->
    {reply, inet:port(State#state.socket), State};
handle_call(region, _From, #state{reg_region = Region} = State) ->
    {reply, {ok, Region}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast({region_params_update, Region, RegionParams}, State) ->
    lager:debug("updating region params. Region: ~p, Params: ~p", [Region, RegionParams]),
    Throttle = miner_lora_throttle:new(Region),
    FreqList = [(blockchain_region_param_v1:channel_frequency(RP) / ?MHzToHzMultiplier) || RP <- RegionParams],
    {noreply, State#state{
            reg_region = Region,
            reg_region_params = RegionParams,
            reg_domain_confirmed = true,
            reg_throttle=Throttle,
            reg_freq_list = FreqList}};
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(init, State = #state{radio_udp_bind_ip = UDPIP, radio_udp_bind_port = UDPPort, following_chain = false}) ->
    %% if we are not following chain then assume validators are running POC challenges and thus
    %% this module will handle lora packets and will need to open the port
    application:set_env(miner, lora_mod, miner_lora_light),
    application:set_env(miner, onion_server_mod, miner_onion_server_light),
    application:set_env(miner, enable_grpc_client, true),
    {ok, Socket, MirrorSocket} = open_socket(UDPIP, UDPPort),
    erlang:send_after(500, self(), reg_domain_timeout),
    {noreply, State#state{socket=Socket, mirror_socket = {MirrorSocket, undefined}}};
handle_info(init, State = #state{radio_udp_bind_ip = UDPIP, radio_udp_bind_port = UDPPort}) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:debug("failed to find chain, will retry in a bit",[]),
            erlang:send_after(500, self(), init),
            {noreply, State};
        Chain ->
            ok = blockchain_event:add_handler(self()),
            Ledger = blockchain:ledger(Chain),
            case blockchain:config(?poc_challenger_type, Ledger) of
                {ok, validator} ->
                    lager:debug("poc_challenger_type: ~p", [validator]),
                    %% we are in validator POC mode, open a socket
                    %% this module will handle lora packets
                    application:set_env(miner, lora_mod, miner_lora_light),
                    application:set_env(miner, onion_server_mod, miner_onion_server_light),
                    application:set_env(miner, enable_grpc_client, true),
                    {ok, Socket, MirrorSocket} = open_socket(UDPIP, UDPPort),
                    {noreply, State#state{chain = Chain, cur_poc_challenger_type = validator, socket=Socket, mirror_socket = {MirrorSocket, undefined}}};
                NonValidatorChallenger ->
                    lager:debug("poc_challenger_type: ~p", [NonValidatorChallenger]),
                    %% we are NOT in validator POC mode, dont open a socket
                    %% instead let the alternative module 'miner_lora' take it
                    %% and handle lora packets
                    application:set_env(miner, lora_mod, miner_lora),
                    application:set_env(miner, onion_server_mod, miner_onion_server),
                    application:set_env(miner, enable_grpc_client, false),
                    {noreply, State#state{cur_poc_challenger_type = NonValidatorChallenger}}
            end
    end;
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    {noreply, State#state{chain = NC}};
handle_info(
    {blockchain_event, {add_block, _BlockHash, _Sync, Ledger} = _Event},
    #state{cur_poc_challenger_type = CurPoCChallengerType} = State
) ->
    case blockchain:config(?poc_challenger_type, Ledger) of
        {ok, V} when V /= CurPoCChallengerType ->
            %% the poc challenger chain var has been modified, force this server
            %% to restart.  It will recheck if it can still bind to the lora port
            %% in addition restart the grpc client so that we start afresh
            _ = miner_poc_grpc_client_statem:stop(),
            {stop, force_restart, State};
        _ ->
            {noreply, State}
    end;
handle_info({blockchain_event, _}, State) ->
    {noreply, State};

handle_info({tx_timeout, Token}, #state{packet_timers=Timers}=State) ->
    case maps:find(Token, Timers) of
        {ok, {send, _Ref, From, _SentAt, _LocalFreq, _TimeOnAir, _HlmPacket}} ->
            gen_server:reply(From, {error, timeout});
        error ->
            ok
    end,
    {noreply, State#state{packet_timers=maps:remove(Token, Timers)}};
handle_info({udp, Socket, IP, Port, Packet}, #state{socket=Socket}=State) ->
    RxInstantLocal_us = erlang:monotonic_time(microsecond),
    maybe_mirror(State#state.mirror_socket, Packet),
    State2 = handle_udp_packet(Packet, IP, Port, RxInstantLocal_us, State),
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
    catch gen_udp:close(Socket),
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

-spec handle_udp_packet(binary(), inet:ip_address(), inet:port_number(), integer(), state()) -> state().
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PUSH_DATA:8/integer-unsigned,
                    MAC:64/integer,
                    JSON/binary>>, IP, Port, RxInstantLocal_us,
                    #state{socket=Socket, gateways=Gateways,
                           reg_domain_confirmed = RegDomainConfirmed}=State) ->
    lager:info("PUSH_DATA ~p from ~p on ~p", [jsx:decode(JSON), MAC, Port]),
    Gateway =
        case maps:find(MAC, Gateways) of
            {ok, #gateway{received=Received}=G} ->
                %% We purposely do not update gateway's addr/port
                %% here. They should only be updated when handling
                %% PULL_DATA, otherwise we may send downlink packets
                %% to the wrong place.
                G#gateway{received=Received+1};
            error ->
                #gateway{mac=MAC, ip=IP, port=Port, received=1}
        end,
    Packet = <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_ACK:8/integer-unsigned>>,
    maybe_mirror(State#state.mirror_socket, Packet),
    maybe_send_udp_ack(Socket, IP, Port, Packet, RegDomainConfirmed),
    handle_json_data(jsx:decode(JSON, [return_maps]), Gateway, RxInstantLocal_us, State);
handle_udp_packet(<<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PULL_DATA:8/integer-unsigned,
                    MAC:64/integer>>, IP, Port, _RxInstantLocal_us, #state{socket=Socket, gateways=Gateways,
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
                    MaybeJSON/binary>>, _IP, _Port, _RxInstantLocal_us, #state{packet_timers=Timers, reg_throttle=Throttle}=State0) ->
    lager:info("TX ack for token ~p ~p", [Token, MaybeJSON]),
    case maps:find(Token, Timers) of
        {ok, {send, Ref, From, SentAt, LocalFreq, TimeOnAir, _HlmPacket}} when MaybeJSON == <<>> -> %% empty string means success, at least with the semtech reference implementation
            _ = erlang:cancel_timer(Ref),
            _ = gen_server:reply(From, ok),
            State0#state{packet_timers=maps:remove(Token, Timers),
                         reg_throttle=miner_lora_throttle:track_sent(Throttle, SentAt, LocalFreq, TimeOnAir)};
        {ok, {send, Ref, From, SentAt, LocalFreq, TimeOnAir, HlmPacket}} ->
            %% likely some kind of error here
            _ = erlang:cancel_timer(Ref),
            State1 = State0#state{packet_timers=maps:remove(Token, Timers)},
            {Reply, NewState} = case kvc:path([<<"txpk_ack">>, <<"error">>], jsx:decode(MaybeJSON)) of
                <<"NONE">> ->
                    lager:info("packet sent ok"),
                    Throttle1 = miner_lora_throttle:track_sent(Throttle, SentAt, LocalFreq, TimeOnAir),
                    {ok, State1#state{reg_throttle=Throttle1}};
                <<"COLLISION_", _/binary>> ->
                    %% colliding with a beacon or another packet, check if join2/rx2 is OK
                    lager:info("collision"),
                    {{error, collision}, State1};
                <<"TOO_LATE">> ->
                    lager:info("too late"),
                    case blockchain_helium_packet_v1:rx2_window(HlmPacket) of
                        undefined -> lager:warning("No RX2 available"),
                                     {{error, too_late}, State1};
                        _ -> retry_with_rx2(HlmPacket, From, State1)
                    end;
                <<"TOO_EARLY">> ->
                    lager:info("too early"),
                    case blockchain_helium_packet_v1:rx2_window(HlmPacket) of
                        undefined -> lager:warning("No RX2 available"),
                                     {{error, too_early}, State1};
                        _ -> retry_with_rx2(HlmPacket, From, State1)
                    end;
                <<"TX_FREQ">> ->
                    %% unmodified 1301 will send this
                    lager:info("tx frequency not supported"),
                    {{error, bad_tx_frequency}, State1};
                <<"TX_POWER">> ->
                    lager:info("tx power not supported"),
                    {{error, bad_tx_power}, State1};
                <<"GPS_UNLOCKED">> ->
                    lager:info("transmitting on GPS time not supported because no GPS lock"),
                    {{error, no_gps_lock}, State1};
                [] ->
                    %% there was no error, see if there was a warning, which implies we sent the packet
                    %% but some correction had to be done.
                    Throttle1 = miner_lora_throttle:track_sent(Throttle, SentAt, LocalFreq, TimeOnAir),
                    case kvc:path([<<"txpk_ack">>, <<"warn">>], jsx:decode(MaybeJSON)) of
                        <<"TX_POWER">> ->
                            %% modified 1301 and unmodified 1302 will send this
                            {{warning, {tx_power_corrected, kvc:path([<<"txpk_ack">>, <<"value">>], jsx:decode(MaybeJSON))}}, State1#state{reg_throttle=Throttle1}};
                        Other ->
                            {{warning, {unknown, Other}}, State1#state{reg_throttle=Throttle1}}
                    end;
                Error ->
                    %% any other errors are pretty severe
                    lager:error("Failure enqueing packet for gateway ~p", [Error]),
                    {{error, {unknown, Error}}, State1}
            end,
            gen_server:reply(From, Reply),
            NewState;
        error ->
            State0
    end;
handle_udp_packet(Packet, _IP, _Port, _RxInstantLocal_us, State) ->
    lager:info("unhandled udp packet ~p", [Packet]),
    State.

-spec handle_json_data(map(), gateway(), integer(), state()) -> state().
handle_json_data(#{<<"rxpk">> := Packets} = Map, Gateway, RxInstantLocal_us, State0) ->
    State1 = handle_packets(sort_packets(Packets), Gateway, RxInstantLocal_us, State0),
    handle_json_data(maps:remove(<<"rxpk">>, Map), Gateway, RxInstantLocal_us, State1);
handle_json_data(#{<<"stat">> := Status} = Map, Gateway0, RxInstantLocal_us, #state{gateways=Gateways}=State) ->
    Gateway1 = Gateway0#gateway{status=Status},
    lager:info("got status ~p", [Status]),
    lager:info("Gateway ~p", [lager:pr(Gateway1, ?MODULE)]),
    Mac = Gateway1#gateway.mac,
    State1 = maybe_update_gps(Status, State),
    handle_json_data(maps:remove(<<"stat">>, Map), Gateway1, RxInstantLocal_us,
                     State1#state{gateways=maps:put(Mac, Gateway1, Gateways)});
handle_json_data(_, _Gateway, _RxInstantLocal_us, State) ->
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
            packet_snr(A) >= packet_snr(B)
        end,
        Packets
    ).

-spec handle_packets(list(), gateway(), integer(), state()) -> state().
handle_packets([], _Gateway, _RxInstantLocal_us, State) ->
    State;
handle_packets(_Packets, _Gateway, _RxInstantLocal_us, #state{reg_domain_confirmed = false} = State) ->
    State;
handle_packets([Packet|Tail], Gateway, RxInstantLocal_us, #state{reg_region = Region} = State) ->
    POCVersion = application:get_env(miner, poc_version, 11),
    Data = base64:decode(maps:get(<<"data">>, Packet)),
    case ?route(Data) of
        error ->
            ok;
        {onion, Payload} ->
            Freq = maps:get(<<"freq">>, Packet),
            %% onion server
            UseRSSIS = case POCVersion of
                X when X > 10 -> true;
                _ -> false
            end,
            miner_onion_server_light:decrypt_radio(
                Payload,
                erlang:trunc(packet_rssi(Packet, UseRSSIS)),
                packet_snr(Packet),
                %% TODO we might want to send GPS time here, if available
                maps:get(<<"tmst">>, Packet),
                Freq,
                channel(Freq, State#state.reg_freq_list),
                maps:get(<<"datr">>, Packet)
            );
        {noop, non_longfi} ->
            %% operating in light mode and embedded gateway enabled so discard non poc packets
            lager:debug("Light mode; miner discarding non-Longfi packet ~p", [Packet]),
            ok;
        {Type, RoutingInfo} ->
            %% normally non-Longfi packets in light mode are discarded but this will
            %% handle when the embedded gateway-rs is disabled and the miner must route the packet
            lager:debug("Routing ~p", [RoutingInfo]),
            erlang:spawn(fun() -> send_to_router(Type, RoutingInfo, Packet, Region))
    end,
    handle_packets(Tail, Gateway, RxInstantLocal_us, State#state{last_mono_us = RxInstantLocal_us, last_tmst_us = maps:get(<<"tmst">>, Packet)}).

-spec route(binary()) -> any().
 route(Pkt) ->
    case longfi:deserialize(Pkt) of
        error ->
            handle_non_longfi(Pkt);
        {ok, LongFiPkt} ->
            %% hello longfi, my old friend
            try longfi:type(LongFiPkt) == monolithic andalso longfi:oui(LongFiPkt) == 0 andalso longfi:device_id(LongFiPkt) == 1 of
                true ->
                    {onion, longfi:payload(LongFiPkt)};
                false ->
                    %% we currently don't expect non-onion packets,
                    %% this is probably a false positive on a LoRaWAN packet
                      handle_non_longfi(Pkt)
            catch _:_ ->
                      handle_non_longfi(Pkt)
            end
    end.

-spec handle_non_longfi(binary()) -> any().
handle_non_longfi(Packet) ->
    case application:get_env(miner, gateway_and_mux_enable) of
        {ok, true} -> {noop, non_longfi};
         -> route_non_longfi(Packet)
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
    %% always ok to use rssis here
    RSSI = packet_rssi(Packet, true),
    SNR = packet_snr(Packet),
    Time = maps:get(<<"tmst">>, Packet),
    Freq = maps:get(<<"freq">>, Packet),
    DataRate = maps:get(<<"datr">>, Packet),
    HeliumPacket = blockchain_helium_packet_v1:new(Type, Data, Time, RSSI, Freq, DataRate, SNR, RoutingInfo),
    blockchain_state_channels_client:packet(HeliumPacket, application:get(miner, default_routers, []), Region).

channel(Freq, Frequencies) ->
    channel(Freq, Frequencies, 0).

channel(Freq, [H|T], Acc) ->
    case abs(H - Freq) =< 0.001 of
        true ->
            Acc;
        false ->
            channel(Freq, T, Acc+1)
    end.

%% @doc returns a tuple of {SpreadingFactor, Bandwidth} from strings like "SFdBWddd"
%%
%% Example: `{7, 125} = scratch:parse_datarate("SF7BW125")'
-spec parse_datarate(string()) -> {integer(), integer()}.
parse_datarate(Datarate) ->
    case Datarate of
        [$S, $F, SF1, SF2, $B, $W, BW1, BW2, BW3] ->
            {erlang:list_to_integer([SF1, SF2]), erlang:list_to_integer([BW1, BW2, BW3])};
        [$S, $F, SF1, $B, $W, BW1, BW2, BW3] ->
            {erlang:list_to_integer([SF1]), erlang:list_to_integer([BW1, BW2, BW3])}
    end.

%% @doc adjusts concentrator timestamp (`tmst`) to a monotonic value.
%%
%% The returned value is a best-effort estimate of what
%% `erlang:monotonic_time(microsecond)` would return if it was called
%% at `Tmst_us`.
-spec tmst_to_local_monotonic_time(immediate | integer(), undefined | integer(), undefined | integer()) -> integer().
tmst_to_local_monotonic_time(immediate, _PrevTmst_us, _PrevMonoTime_us) ->
    erlang:monotonic_time(microsecond);
tmst_to_local_monotonic_time(_When, undefined, undefined) ->
    %% We haven't yet received a `tmst` from the packet forwarder, so
    %% we don't have anything to track. Let's just use the current
    %% time and hope for the best.
    erlang:monotonic_time(microsecond);
tmst_to_local_monotonic_time(Tmst_us, PrevTmst_us, PrevMonoTime_us) when Tmst_us >= PrevTmst_us ->
    Tmst_us - PrevTmst_us + PrevMonoTime_us;
tmst_to_local_monotonic_time(Tmst_us, PrevTmst_us, PrevMonoTime_us) ->
    %% Because `Tmst_us` is less than the last `tmst` we received from
    %% the packet forwarder, we allow for the possibility one single
    %% roll over of the clock has occurred, and that `Tmst_us` might
    %% represent a time in the future.
    Tmst_us + ?MAX_TMST_VAL - PrevTmst_us + PrevMonoTime_us.

%% Extracts a packet's RSSI, abstracting away the differences between
%% GWMP JSON V1/V2.
-spec packet_rssi(map(), boolean()) -> number().
packet_rssi(Packet, UseRSSIS) ->
    RSSIS = maps:get(<<"rssis">>, Packet, undefined),
    SingleRSSI = case UseRSSIS andalso RSSIS =/= undefined of
        true  -> RSSIS;
        false -> maps:get(<<"rssi">>, Packet, undefined)
    end,
    case SingleRSSI of
        %% No RSSI, perhaps this is a GWMP V2
        undefined ->
            %% `rsig` is a list. It can contain more than one signal
            %% quality object if the packet was received on multiple
            %% antennas/receivers. So let's pick the one with the
            %% highest RSSI.
            FetchRSSI = case UseRSSIS of
                true ->
                    %% Use RSSIS if available, fall back to RSSIC.
                    fun (Obj) ->
                        maps:get(<<"rssis">>, Obj,
                                 maps:get(<<"rssic">>, Obj, undefined))
                    end;
                false ->
                    %% Just use RSSIC.
                    fun (Obj) ->
                        maps:get(<<"rssic">>, Obj, undefined)
                    end
            end,
            BestRSSISelector =
                fun (Obj, Best) ->
                    erlang:max(Best, FetchRSSI(Obj))
                end,
            [H|T] = maps:get(<<"rsig">>, Packet),
            lists:foldl(BestRSSISelector, FetchRSSI(H), T);
        %% GWMP V1
        RSSI ->
            RSSI
    end.

%% Extracts a packet's SNR, abstracting away the differences between
%% GWMP JSON V1/V2.
-spec packet_snr(map()) -> number().
packet_snr(Packet) ->
    case maps:get(<<"lsnr">>, Packet, undefined) of
        %% GWMP V2
        undefined ->
            %% `rsig` is a list. It can contain more than one signal
            %% quality object if the packet was received on multiple
            %% antennas/receivers. So let's pick the one with the
            %% highest SNR
            [H|T] = maps:get(<<"rsig">>, Packet),
            Selector = fun(Obj, Best) ->
                               erlang:max(Best, maps:get(<<"lsnr">>, Obj))
                       end,
            lists:foldl(Selector, maps:get(<<"lsnr">>, H), T);
        %% GWMP V1
        LSNR ->
            LSNR
    end.

-spec send_packet(
    Payload :: binary(),
    When :: integer(),
    ChannelSelectorFun :: fun(),
    DataRate :: string(),
    Power :: float(),
    IPol :: boolean(),
    HlmPacket :: helium_packet(),
    From :: {pid(), reference()},
    State :: state()
) -> {error, any()} | {ok, state()}.
send_packet(Payload, When, ChannelSelectorFun, DataRate, Power, IPol, HlmPacket, From,
            #state{socket=Socket,
                   gateways=Gateways,
                   packet_timers=Timers,
                   reg_freq_list=Freqs,
                   reg_throttle=Throttle,
                   last_tmst_us=PrevTmst_us,
                   last_mono_us=PrevMono_us}=State) ->
    case select_gateway(Gateways) of
        {error, _}=Error ->
            Error;
        {ok, #gateway{ip=IP, port=Port}} ->
            lager:info("PULL_RESP to ~p:~p", [IP, Port]),
            %% the fun is set by the sender and is used to deterministically route data via channels
            LocalFreq = ChannelSelectorFun(Freqs),

            %% Check this transmission for regulatory compliance.
            {SpreadingFactor, Bandwidth} = parse_datarate(DataRate),
            TimeOnAir = miner_lora_throttle:time_on_air(Bandwidth, SpreadingFactor, 5, 8, true, byte_size(Payload)),
            AdjustedTmst_us = tmst_to_local_monotonic_time(When, PrevTmst_us, PrevMono_us),
            SentAt = AdjustedTmst_us / 1000,
            case miner_lora_throttle:can_send(Throttle, SentAt, LocalFreq, TimeOnAir) of
                false -> lager:warning("This transmission should have been rejected");
                true -> ok
            end,

            Token = mk_token(Timers),
            Packet = create_packet(Payload, When, LocalFreq, DataRate, Power, IPol, Token),
            maybe_mirror(State#state.mirror_socket, Packet),
            lager:debug("sending packet via channel: ~p",[LocalFreq]),
            ok = gen_udp:send(Socket, IP, Port, Packet),
            %% TODO a better timeout would be good here
            Ref = erlang:send_after(10000, self(), {tx_timeout, Token}),
            {ok, State#state{packet_timers=maps:put(Token, {send, Ref, From, SentAt, LocalFreq, TimeOnAir, HlmPacket}, Timers)}}
    end.

-spec create_packet(
    Payload :: binary(),
    When :: atom() | integer(),
    LocalFreq :: integer(),
    DataRate :: string(),
    Power :: float(),
    IPol :: boolean(),
    Token :: binary()
) -> binary().
create_packet(Payload, When, LocalFreq, DataRate, Power, IPol, Token) ->

    IsImme = When == immediate,
    Tmst = case IsImme of
               false -> When;
               true -> 0
           end,

    DecodedJSX = #{<<"txpk">> => #{
                        <<"ipol">> => IPol, %% IPol for downlink to devices only, not poc packets
                        <<"imme">> => IsImme,
                        <<"powe">> => trunc(Power),
                        <<"tmst">> => Tmst,
                        <<"freq">> => LocalFreq,
                        <<"modu">> => <<"LORA">>,
                        <<"datr">> => list_to_binary(DataRate),
                        <<"codr">> => <<"4/5">>,
                        <<"size">> => byte_size(Payload),
                        <<"rfch">> => 0,
                        <<"data">> => base64:encode(Payload)
                    }
                },
    BinJSX = jsx:encode(DecodedJSX),
    lager:debug("PULL_RESP: ~p",[DecodedJSX]),
    lager:debug("sending packet via channel: ~p",[LocalFreq]),
    <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, BinJSX/binary>>.

-spec retry_with_rx2(
    HlmPacket0 :: helium_packet(),
    From :: {pid(), reference()},
    State :: state()
) -> {error, any()} | {ok, state()}.
retry_with_rx2(HlmPacket0, From, State) ->
    #window_pb{timestamp=TS,
               frequency=Freq,
               datarate=DataRate} = blockchain_helium_packet_v1:rx2_window(HlmPacket0),
    lager:info("Retrying with RX2 window ~p", [TS]),
    Power = blockchain_helium_packet_v1:signal_strength(HlmPacket0),
    Payload = blockchain_helium_packet_v1:payload(HlmPacket0),
    ChannelSelectorFun = fun(_FreqList) -> Freq end,
    HlmPacket1 = HlmPacket0#packet_pb{rx2_window=undefined},
    send_packet(Payload, TS, ChannelSelectorFun, DataRate, Power, true, HlmPacket1, From, State).

-spec open_socket(string(), pos_integer()) -> {ok, port(), port()}.
open_socket(IP, Port) ->
    {ok, Socket} = gen_udp:open(Port, [binary, {reuseaddr, true}, {active, 100}, {ip, IP}]),
    MirrorSocket =
        case application:get_env(miner, radio_mirror_port, undefined) of
            undefined ->
                undefined;
            P ->
                {ok, MS} = gen_udp:open(P, [binary, {active, true}]),
                MS
        end,
    {ok, Socket, MirrorSocket}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

rssi_fetch_test() ->
    PacketWithRSSIS = #{
        <<"rssis">> => 1,
        <<"rssi">> => 2
    },
    PacketWithoutRSSIS = #{
        <<"rssi">> => 2
    },
    RSIGPacketWithRSSIS = #{
        <<"rsig">> => [
            #{ <<"rssis">> => 1, <<"rssic">> => 2 },
            #{ <<"rssis">> => 3, <<"rssic">> => 4 },
            #{ <<"rssis">> => -1, <<"rssic">> => 0 }
        ]
    },
    RSIGPacketWithoutRSSIS = #{
        <<"rsig">> => [
            #{ <<"rssic">> => 2 },
            #{ <<"rssic">> => 4 },
            #{ <<"rssic">> => 0 }
        ]
    },
    ?assertEqual(packet_rssi(PacketWithRSSIS, true), 1),
    ?assertEqual(packet_rssi(PacketWithRSSIS, false), 2),
    ?assertEqual(packet_rssi(PacketWithoutRSSIS, true), 2),
    ?assertEqual(packet_rssi(PacketWithoutRSSIS, false), 2),
    ?assertEqual(packet_rssi(RSIGPacketWithRSSIS, true), 3),
    ?assertEqual(packet_rssi(RSIGPacketWithRSSIS, false), 4),
    ?assertEqual(packet_rssi(RSIGPacketWithoutRSSIS, true), 4),
    ?assertEqual(packet_rssi(RSIGPacketWithoutRSSIS, false), 4).

-endif.
