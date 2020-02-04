-module(miner_fake_radio_backplane).

-behaviour(gen_server).

-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("miner_ct_macros.hrl").
-include("lora.hrl").

-record(state, {
          udp_sock,
          udp_ports
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

start_link(MyPort, UDPPorts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [MyPort, UDPPorts], []).

init([MyPort, UDPPorts]) ->
    %% create UDP client port
    {ok, Sock} = gen_udp:open(MyPort, [binary, {active, true}, {reuseaddr, true}]),
    Token = <<0, 0>>,
    [ gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, 16#deadbeef:64/integer>>) || {Port, _} <- UDPPorts],
    {ok, #state{udp_sock=Sock, udp_ports=UDPPorts}}.

handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    {reply, error, State}.

handle_cast(Msg, State) ->
    lager:warning("unhandled cast ~p", [Msg]),
    {noreply, State}.

handle_info(go, State) ->
    Token = <<0, 0>>,
    [ gen_udp:send(State#state.udp_sock, {127, 0, 0, 1}, Port, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, 16#deadbeef:64/integer>>) || {Port, _} <- State#state.udp_ports],
    {noreply, State};
handle_info({udp, UDPSock, IP, SrcPort, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_RESP:8/integer-unsigned, JSON/binary>>},
            State = #state{udp_sock=UDPSock, udp_ports=Ports}) ->
    gen_udp:send(UDPSock, IP, SrcPort, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, 16#deadbeef:64/integer>>),
    #{<<"txpk">> := Packet} = jsx:decode(JSON, [return_maps]),
    ct:pal("Source port ~p, Ports ~p", [SrcPort, Ports]),
    {SrcPort, OriginLocation} = lists:keyfind(SrcPort, 1, Ports),
    lists:foreach(
        fun({Port, Location}) ->
                Distance = blockchain_utils:distance(OriginLocation, Location),
                %% FreeSpacePathLoss = ?TRANSMIT_POWER - (32.44 + 20*math:log10(?FREQUENCY) + 20*math:log10(Distance) - ?MAX_ANTENNA_GAIN - ?MAX_ANTENNA_GAIN),
                case Distance > 32 of
                    true ->
                        ct:pal("NOT sending from ~p to ~p -> ~p km", [OriginLocation, Location, Distance]),
                        ok;
                    false ->
                        ApproxRSSI = approx_rssi(Distance),
                        NewJSON = #{<<"rxpk">> => [maps:merge(maps:without([<<"imme">>, <<"rfch">>, <<"powe">>], Packet), #{<<"rssi">> => ApproxRSSI, <<"snr">> => 1.0, <<"tmst">> => erlang:system_time(seconds)})]},
                        ct:pal("sending ~p from ~p to ~p -> ~p km RSSI ~p", [NewJSON, OriginLocation, Location, Distance, ApproxRSSI]),
                        gen_udp:send(UDPSock, {127, 0, 0, 1}, Port, <<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, 16#deadbeef:64/integer, (jsx:encode(NewJSON))/binary>>)
                end
        end,
        lists:keydelete(SrcPort, 1, Ports)
    ),
    {noreply, State};
handle_info(Msg, State) ->
    ct:pal("unhandled info ~p", [Msg]),
    {noreply, State}.

%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------
approx_rssi(Distance) ->
    ?ABS_RSSI - ?ETA * (10 * math:log10(Distance * 1000)).
