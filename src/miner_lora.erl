-module(miner_lora).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(PROTOCOL_2, 2).
-define(PUSH_DATA, 0).
-define(PUSH_ACK, 1).
-define(PULL_DATA, 2).
-define(PULL_RESP, 3).
-define(PULL_ACK, 4).
-define(TX_ACK, 5).

-define(JOIN_REQUEST, 2#000).
-define(JOIN_ACCEPT, 2#001).
-define(UNCONFIRMED_UP, 2#010).
-define(UNCONFIRMED_DOWN, 2#011).
-define(CONFIRMED_UP, 2#100).
-define(CONFIRMED_DOWN, 2#101).

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
          miner_name
         }).

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init(Args) ->
    {ok, Name} = erl_angry_purple_tiger:animal_name(libp2p_crypto:bin_to_b58(blockchain_swarm:pubkey_bin())),
    MinerName = binary:replace(erlang:list_to_binary(Name), <<"-">>, <<" ">>, [global]),
    UDPIP = maps:get(radio_udp_bind_ip, Args),
    {ok, Socket} = gen_udp:open(1680, [binary, {active, 100}, {ip, UDPIP}]),
    {ok, #state{socket=Socket,
                miner_name = unicode:characters_to_binary(MinerName, utf8)
               }}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Packet}, State = #state{socket=Socket}) ->
    State2 = handle(Packet, IP, Port, State),
    {noreply, State2};
handle_info({udp_passive, Socket}, State = #state{socket=Socket}) ->
    inet:setopts(Socket, [{active, 100}]),
    {noreply, State};
handle_info({send, Packet}, State) ->
    Token = crypto:strong_rand_bytes(2),
    Gateway = element(2, hd(maps:to_list(State#state.gateways))),
    ok = gen_udp:send(State#state.socket, Gateway#gateway.ip, Gateway#gateway.port, <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_RESP:8/integer-unsigned, Packet/binary>>),
    Ref = make_ref(),
    {noreply, State#state{packet_timers = maps:put(Token, {send, Ref, join1_window, Packet, <<>>}, State#state.packet_timers)}};
handle_info(Msg, State) ->
    lager:debug("unexpected message ~p", [Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State = #state{socket=Socket}) ->
    gen_udp:close(Socket),
    ok.

handle(<<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PUSH_DATA:8/integer-unsigned, MAC:64/integer, JSON/binary>>, IP, Port, State) ->
    lager:info("PUSH_DATA ~p from ~p on ~p", [jsx:decode(JSON), MAC, Port]),
    case maps:find(MAC, State#state.gateways) of
        {ok, G} ->
            gen_udp:send(State#state.socket, IP, Port, <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PUSH_ACK:8/integer-unsigned>>),
            Received = G#gateway.received,
            Gateway = G#gateway{received=Received+1},
            handle_DATA(jsx:decode(JSON), Gateway, State);
        error ->
            lager:warning("discarding packet ~p", [JSON]),
            State
    end;
handle(<<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?PULL_DATA:8/integer-unsigned, MAC:64/integer>>, IP, Port, State) ->
    gen_udp:send(State#state.socket, IP, Port, <<?PROTOCOL_2:8/integer-unsigned, Token/binary, ?PULL_ACK:8/integer-unsigned>>),
    lager:info("PULL_DATA from ~p on ~p", [MAC, Port]),
    Gateway = case maps:find(MAC, State#state.gateways) of
                  {ok, G} ->
                      Received = G#gateway.received,
                      G#gateway{ip=IP, port=Port, received=Received+1};
                  error ->
                      #gateway{mac=MAC, ip=IP, port=Port, received=1}
              end,
    State#state{gateways = maps:put(MAC, Gateway, State#state.gateways)};
handle(<<?PROTOCOL_2:8/integer-unsigned, Token:2/binary, ?TX_ACK:8/integer-unsigned, MAC:64/integer, MaybeJSON/binary>>, _IP, _Port, State0) ->
    lager:info("TX ack for token ~p ~p", [Token, MaybeJSON]),
    case maps:find(Token, State0#state.packet_timers) of
        {ok, {Ref, Timestamp, _Count}} ->
            RTT = timer:now_diff(os:timestamp(), Timestamp),
            lager:info("RTT is ~p ", [RTT/1000.0]),
            erlang:cancel_timer(Ref),
            State = State0#state{packet_timers = maps:remove(Token, State0#state.packet_timers)},
            Gateway0 = maps:get(MAC, State#state.gateways),
            Gateway1 = Gateway0#gateway{rtt_samples = [RTT|Gateway0#gateway.rtt_samples]},
            %% don't let the RTT go lower than 50ms
            Gateway2 = Gateway1#gateway{rtt = max(50000, trunc(lists:sum(Gateway1#gateway.rtt_samples)/length(Gateway1#gateway.rtt_samples)))},
            State#state{gateways = maps:put(MAC, Gateway2, State#state.gateways)};
        {ok, {send, Ref, _Window, _, _}} when MaybeJSON == <<>> -> %% empty string means success, at least with the semtech reference implementation
            erlang:cancel_timer(Ref),
            State0;
        {ok, {send, Ref, _Window, _InPkt, _OutPkt}} ->
            %% likely some kind of error here
            erlang:cancel_timer(Ref),
            State = State0#state{packet_timers = maps:remove(Token, State0#state.packet_timers)},
            case kvc:path([<<"txpk_ack">>, <<"error">>], jsx:decode(MaybeJSON)) of
                <<"NONE">> ->
                    lager:info("packet sent ok");
                <<"COLLISION_", _/binary>> ->
                    %% colliding with a beacon or another packet, check if join2/rx2 is OK
                    lager:info("collision");
                    %retry_packet(MAC, get_next_window(Window), InPkt, OutPkt, State);
                <<"TOO_LATE">> ->
                    lager:info("too late");
                    %% check if join2/rx2 is OK
                    %retry_packet(MAC, get_next_window(Window), InPkt, OutPkt, State);
                Error ->
                    %% any other errors are pretty severe
                    lager:error("Failure enqueing packet for gateway ~p", [Error])
            end,
            State;
        error ->
            State0
    end;
handle(Packet, _IP, _Port, State) ->
    lager:info("unhandled packet ~p", [Packet]),
    State.

handle_DATA([], _Gateway, State) ->
    State;
handle_DATA([{<<"rxpk">>, Packets}|Tail], Gateway, State) ->
    State2 = handle_packet(sort_packets(Packets), Gateway, State),
    handle_DATA(Tail, Gateway, State2);
handle_DATA([{<<"stat">>, Status}|Tail], Gateway0, State) ->
    Gateway = Gateway0#gateway{status=Status},
    lager:info("got status ~p", [Status]),
    lager:info("Gateway ~p", [lager:pr(Gateway, ?MODULE)]),
    handle_DATA(Tail, Gateway, State#state{gateways = maps:put(Gateway#gateway.mac, Gateway, State#state.gateways)}).

handle_packet([], _Gateway, State) ->
    State;
handle_packet([Packet|Tail], Gateway, State) ->
    Data = base64:decode(proplists:get_value(<<"data">>, Packet)),
    lager:notice("Routing ~p", [route(Data)]),
    erlang:spawn(fun() -> send_to_router(State#state.miner_name, {route(Data), Packet})  end),
    handle_packet(Tail, Gateway, State).


route(<<2#000:3, _:5, AppEUI0:8/binary, _DevEUI0:8/binary, _DevNonce:2/binary, _MIC:4/binary>>) ->
    <<OUI:32/integer-unsigned-big, _DID:32/integer-unsigned-big>> = reverse(AppEUI0),
    OUI;
route(<<_MType:3, _:5,DevAddr0:4/binary, _ADR:1, _ADRACKReq:1, _ACK:1, _RFU:1, FOptsLen:4, _FCnt:16/little-unsigned-integer, _FOpts:FOptsLen/binary, PayloadAndMIC/binary>>) ->
    Body = binary:part(PayloadAndMIC, {0, byte_size(PayloadAndMIC) -4}),
    {FPort, _FRMPayload} = case Body of
                              <<>> -> {undefined, <<>>};
                              <<Port:8, Payload/binary>> -> {Port, Payload}
                          end,
    case FPort of
        0 when FOptsLen /= 0 ->
            error;
        _ ->
            <<OUI:32/integer-unsigned-big>> = reverse(DevAddr0),
            OUI
    end;
route(Pkt) ->
    lager:info("Unknown packet ~w", [Pkt]),
    %% TODO longfi
    error.

reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

sort_packets(Packets) ->
    R = lists:sort(fun(A, B) ->
                       proplists:get_value(<<"lsnr">>, A) >= proplists:get_value(<<"lsnr">>, B)
               end, Packets),
    R.

send_to_router(_Name, {error, _Packet}) ->
    ok;
send_to_router(_Name, {OUI, Packet}) ->
    case blockchain_worker:blockchain() of
        undefined ->
            lager:warning("ingnored packet chain is undefined");
        Chain ->
            Ledger = blockchain:ledger(Chain),
            Swarm = blockchain_swarm:swarm(),
            case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                {error, _Reason} ->
                    case application:get_env(miner, default_router, undefined) of
                        undefined ->
                            lager:warning("ingnored could not find OUI ~p in ledger and no default router is set", [OUI]);
                        Address ->
                            send_to_router(Swarm, Address, jsx:encode(Packet))
                    end;
                {ok, Routing} ->
                    Addresses = blockchain_ledger_routing_v1:addresses(Routing),
                    lager:debug("found addresses ~p", [Addresses]),
                    lists:foreach(
                        fun(BinAddress) ->
                            Address = erlang:binary_to_list(BinAddress),
                            send_to_router(Swarm, Address, jsx:encode(Packet))
                        end,
                        Addresses
                    )
            end
    end.

send_to_router(Swarm, Address, Packet) ->
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

