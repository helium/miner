-module(miner_fake_radio_backplane).

-behaviour(gen_server).

-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
          listen_sock,
          udp_sock,
          sockets = [],
          udp_ports
         }).

-define(WRITE_RADIO_PACKET, 16#0).
-define(WRITE_RADIO_PACKET_ACK, 16#80).
-define(READ_RADIO_PACKET, 16#81).
-define(READ_RADIO_PACKET_EXTENDED, 16#82).

start_link(TCPPort, UDPPorts) ->
    gen_server:start_link(?MODULE, [TCPPort, UDPPorts], []).

init([TCPPort, UDPPorts]) ->
    %% create UDP client port
    {ok, UDP} = gen_udp:open(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Sock} = gen_tcp:listen(TCPPort, [binary, {active, false}, {reuseaddr, true}, {packet, 2}, {nodelay, true}]),
    Parent = self(),
    spawn_link(fun() -> accept_loop(Parent, Sock) end),
    {ok, #state{listen_sock=Sock, udp_sock=UDP, udp_ports=UDPPorts}}.

handle_call(Msg, _From, State) ->
    lager:warning("unhandled call ~p", [Msg]),
    {reply, error, State}.

handle_cast(Msg, State) ->
    lager:warning("unhandled cast ~p", [Msg]),
    {noreply, State}.

handle_info({new_connection, Socket}, State = #state{sockets=Sockets}) ->
    inet:setopts(Socket, [{active, true}]),
    {noreply, State#state{sockets=[Socket|Sockets]}};
handle_info({tcp, Socket, <<?WRITE_RADIO_PACKET, Packet/binary>>}, State = #state{udp_sock=UDPSock, udp_ports=Ports}) ->
    lists:foreach(fun(Port) ->
                          gen_udp:send(UDPSock, {127, 0, 0, 1}, Port, <<?READ_RADIO_PACKET, Packet/binary>>)
                  end, Ports),
    gen_tcp:send(Socket, <<?WRITE_RADIO_PACKET_ACK>>),
    {noreply, State};
handle_info({tcp_closed, Socket}, State = #state{sockets=Sockets}) ->
    {noreply, State#state{sockets=Sockets -- [Socket]}};
handle_info({tcp_error, Socket, _Reason}, State = #state{sockets=Sockets}) ->
    {noreply, State#state{sockets=Sockets -- [Socket]}};
handle_info(Msg, State) ->
    lager:warning("unhandled info ~p", [Msg]),
    {noreply, State}.

accept_loop(Parent, LSock) ->
    {ok, Socket} = gen_tcp:accept(LSock),
    case gen_tcp:controlling_process(Socket, Parent) of
        ok ->
            Parent ! {new_connection, Socket};
        _ ->
            ok
    end,
    accept_loop(Parent, LSock).
