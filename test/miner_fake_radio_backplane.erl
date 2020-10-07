-module(miner_fake_radio_backplane).

-behaviour(gen_server).

-export([start_link/3, start_link/4,
         init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([transmit/3, get_next_packet/0]).

-include("miner_ct_macros.hrl").
-include("lora.hrl").

-include_lib("blockchain/include/blockchain_utils.hrl").

-record(state, {
          udp_sock,
          udp_ports,
          poc_version,
          mirror
         }).

-define(WRITE_RADIO_PACKET, 16#0).
-define(WRITE_RADIO_PACKET_ACK, 16#80).
-define(READ_RADIO_PACKET, 16#81).
-define(READ_RADIO_PACKET_EXTENDED, 16#82).

-define(FREQUENCY, 915).
-define(TRANSMIT_POWER, 28).
-define(MAX_ANTENNA_GAIN, 6).
-define(ETA, 1.8).
-define(ABS_RSSI, -48).

start_link(POCVersion, MyPort, UDPPorts) ->
    start_link(POCVersion, MyPort, UDPPorts, true).

start_link(POCVersion, MyPort, UDPPorts, Status) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [POCVersion, MyPort, UDPPorts, Status], []).

transmit(Payload, Frequency, TxLocation) ->
    gen_server:cast(?MODULE, {transmit, Payload, Frequency, TxLocation}).

get_next_packet() ->
    gen_server:cast(?MODULE, {get_next, self()}).

init([POCVersion, MyPort, UDPPorts, Status]) ->
    %% create UDP client port
    {ok, Sock} = gen_udp:open(MyPort, [binary, {active, true}, {reuseaddr, true}]),
    Token = <<0, 0>>,
    [gen_udp:send(Sock, {127, 0, 0, 1}, Port,
                  <<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PULL_DATA:8/integer-unsigned,
                    16#deadbeef:64/integer>>)
     || {Port, _} <- UDPPorts],
    case Status of
        true ->
            %% short initial tick, as we need to race the first request :/
            erlang:send_after(0, self(), status_tick);
        _ ->
            %% just don't start the tick
            ok
    end,
    State = #state{poc_version=POCVersion, udp_sock=Sock, udp_ports=UDPPorts},
    ct:pal("starting fake_radio_backplane, state: ~p", [State]),
    {ok, State}.

handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    {reply, error, State}.

handle_cast({get_next, Pid}, State) ->
    {noreply, State#state{mirror=Pid}};
handle_cast({transmit, Payload, Frequency, TxLocation}, State = #state{udp_sock=UDPSock, udp_ports=Ports, poc_version=POCVersion}) ->
    ct:pal("transmitting"),
    Token = crypto:strong_rand_bytes(2),
    lists:foreach(
        fun({Port, Location}) ->
                Distance = blockchain_utils:distance(TxLocation, Location),
                RSSI = case POCVersion of
                           V when V >= 9 ->
                               blockchain_utils:min_rcv_sig(blockchain_utils:free_space_path_loss(TxLocation, Location, Frequency));
                           V when V >= 8 ->
                               FreeSpacePathLoss = ?TRANSMIT_POWER - (32.44 + 20*math:log10(?FREQUENCY) + 20*math:log10(Distance) - ?MAX_ANTENNA_GAIN - ?MAX_ANTENNA_GAIN),
                               FreeSpacePathLoss;
                           _ ->
                               %% Use approx_rssi poc_version 8 onwards
                               approx_rssi(Distance)
                       end,
                case Distance > 32 of
                    true -> ok;
                    false ->
                        NewJSON = #{<<"rxpk">> => [#{<<"rssi">> => RSSI,
                                                     <<"lsnr">> => approx_snr(RSSI),
                                                     <<"tmst">> => erlang:system_time(seconds),
                                                     <<"data">> => base64:encode(Payload),
                                                     <<"freq">> => Frequency,
                                                     <<"datr">> => <<"SF8BW125">>}]},
                        ct:pal("Sending ~p ~p", [Port, NewJSON]),
                        gen_udp:send(UDPSock, {127, 0, 0, 1},
                                     Port,
                                     <<?PROTOCOL_2:8/integer-unsigned,
                                       Token:2/binary,
                                       ?PUSH_DATA:8/integer-unsigned,
                                       16#deadbeef:64/integer,
                                       (jsx:encode(NewJSON))/binary>>)
                end
        end,
        Ports
    ),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:warning("unhandled cast ~p", [Msg]),
    {noreply, State}.

handle_info(go, State) ->
    Token = <<0, 0>>,
    [ gen_udp:send(State#state.udp_sock, {127, 0, 0, 1}, Port, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, 16#deadbeef:64/integer>>) || {Port, _} <- State#state.udp_ports],
    {noreply, State};
handle_info({udp, UDPSock, IP, SrcPort, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_RESP:8/integer-unsigned, JSON/binary>>},
            State = #state{udp_sock=UDPSock, udp_ports=Ports, poc_version=POCVersion}) ->
    gen_udp:send(UDPSock, IP, SrcPort, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, 16#deadbeef:64/integer>>),
    #{<<"txpk">> := Packet} = jsx:decode(JSON, [return_maps]),
    #{<<"freq">> := Frequency} = Packet,

    case State#state.mirror of
        Pid when is_pid(Pid) ->
            Pid ! {fake_radio_backplane, Packet};
        _ ->
            ok
    end,
    %ct:pal("Source port ~p, Ports ~p", [SrcPort, Ports]),
    {SrcPort, OriginLocation} = lists:keyfind(SrcPort, 1, Ports),
    lists:foreach(
        fun({Port, Location}) ->
                Distance = blockchain_utils:distance(OriginLocation, Location),
                ToSend = case POCVersion of
                             V when V >= 9 ->
                                 FSPL = blockchain_utils:min_rcv_sig(blockchain_utils:free_space_path_loss(OriginLocation, Location, Frequency)),
                                 {FSPL, approx_snr(FSPL)};
                             V when V < 8 ->
                                 FreeSpacePathLoss = ?TRANSMIT_POWER - (32.44 + 20*math:log10(?FREQUENCY) + 20*math:log10(Distance) - ?MAX_ANTENNA_GAIN - ?MAX_ANTENNA_GAIN),
                                 {FreeSpacePathLoss, 1.0};
                             _ ->
                                 %% Use approx_rssi poc_version 8 onwards
                                 {approx_rssi(Distance), 1.0}
                         end,
                {ToSendRSSI, ToSendSNR} = ToSend,
                do_send(ToSendRSSI, ToSendSNR, Distance, OriginLocation, Location, Token, Packet, UDPSock, Port)
        end,
        lists:keydelete(SrcPort, 1, Ports)
    ),
    {noreply, State#state{mirror=undefined}};
handle_info({udp, _UDPSock, _IP, _SrcPort, <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PUSH_ACK:8/integer-unsigned>>}, State) ->
    {noreply, State};
handle_info({udp, _UDPSock, _IP, _SrcPort, <<?PROTOCOL_2:8/integer-unsigned, _Token:2/binary, ?PULL_ACK:8/integer-unsigned>>}, State) ->
    {noreply, State};
handle_info(status_tick, State) ->
    erlang:send_after(1000, self(), status_tick),
    _ = send_status_packets(State),
    {noreply, State};
handle_info(Msg, State) ->
    ct:pal("unhandled info ~p", [Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------

send_status_packets(#state{udp_sock = Sock, udp_ports = UDPPorts}) ->
    [begin
         {Lat, Long} = h3:to_geo(Loc),
         Token = <<0, 0>>,
         Data = jsx:encode(#{<<"stat">> =>
                                 #{<<"lati">> => Lat,
                                   <<"long">> => Long}}),
         gen_udp:send(Sock, {127, 0, 0, 1}, Port,
                  <<?PROTOCOL_2:8/integer-unsigned,
                    Token:2/binary,
                    ?PUSH_DATA:8/integer-unsigned,
                    16#deadbeef:64/integer,
                    Data/binary>>)
     end
     || {Port, Loc} <- UDPPorts].

approx_rssi(Distance) ->
    ?ABS_RSSI - ?ETA * (10 * math:log10(Distance * 1000)).

do_send(ToSendRSSI, ToSendSNR, Distance, _OriginLocation, _Location, Token, Packet, UDPSock, Port) ->
    case Distance > 32 of
        true ->
            ct:pal("NOT sending from ~p to ~p -> ~p km", [_OriginLocation, _Location, Distance]),
            ok;
        false ->
            NewJSON = #{<<"rxpk">> => [maps:merge(maps:without([<<"imme">>, <<"rfch">>, <<"powe">>], Packet), #{<<"rssi">> => ToSendRSSI, <<"lsnr">> => ToSendSNR, <<"tmst">> => erlang:system_time(seconds)})]},
            ct:pal("sending ~p from ~p to ~p -> ~p km RSSI ~p, SNR ~p", [NewJSON, _OriginLocation, _Location, Distance, ToSendRSSI, ToSendSNR]),
            gen_udp:send(UDPSock, {127, 0, 0, 1}, Port, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer, (jsx:encode(NewJSON))/binary>>)
    end.

approx_snr(FSPL) ->
    PotentialSNRs = maps:keys(maps:filter(
                                fun(_SNR, {Low, High}) ->
                                        FSPL >= Low andalso FSPL =< High
                                end, ?SNR_CURVE)),
    case PotentialSNRs of
        [] -> -20;
        SNRs -> hd(SNRs)
    end.
