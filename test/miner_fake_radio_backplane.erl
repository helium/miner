-module(miner_fake_radio_backplane).

-behaviour(gen_server).

-include("pb/concentrate_pb.hrl").

-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
          udp_sock,
          udp_ports
         }).

-define(WRITE_RADIO_PACKET, 16#0).
-define(WRITE_RADIO_PACKET_ACK, 16#80).
-define(READ_RADIO_PACKET, 16#81).
-define(READ_RADIO_PACKET_EXTENDED, 16#82).

start_link(MyPort, UDPPorts) ->
    gen_server:start_link(?MODULE, [MyPort, UDPPorts], []).

init([MyPort, UDPPorts]) ->
    %% create UDP client port
    {ok, Sock} = gen_udp:open(MyPort, [binary, {active, true}, {reuseaddr, true}]),
    {ok, #state{udp_sock=Sock, udp_ports=UDPPorts}}.

handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    {reply, error, State}.

handle_cast(Msg, State) ->
    lager:warning("unhandled cast ~p", [Msg]),
    {noreply, State}.

handle_info({udp, UDPSock, _IP, SrcPort, InPacket}, State = #state{udp_sock=UDPSock, udp_ports=Ports}) ->
    #miner_Req_pb{kind={tx, #miner_TxReq_pb{payload=Payload}}} = concentrate_pb:decode_msg(InPacket, miner_Req_pb),
    lists:foreach(fun(Port) ->
                          gen_udp:send(UDPSock, {127, 0, 0, 1}, Port, concentrate_pb:encode_msg(#miner_Resp_pb{kind={rx_packet, #miner_RxPacket_pb{payload=Payload, crc_check=true}}}))
                  end, Ports -- [SrcPort]),
    {noreply, State};
handle_info(Msg, State) ->
    ct:pal("unhandled info ~p", [Msg]),
    {noreply, State}.
