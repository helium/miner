-module(miner_test_sc_packet_handler).

-export([handle_packet/2]).

handle_packet(Packet, HandlerPid) ->
    lager:info("Packet: ~p, HandlerPid: ~p", [Packet, HandlerPid]),
    ok.
