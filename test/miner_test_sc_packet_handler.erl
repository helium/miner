-module(miner_test_sc_packet_handler).

-export([handle_packet/1]).

handle_packet(Packet) ->
    lager:info("Packet: ~p", [Packet]),
    ok.
