-module(miner_test_sc_packet_handler).

-export([handle_packet/3, handle_offer/2]).

handle_packet(Packet, _PacketTime, HandlerPid) ->
    F = application:get_env(blockchain, sc_packet_handler_packet_fun, fun(_Packet) -> ok end),
    lager:info("Packet: ~p, HandlerPid: ~p", [Packet, HandlerPid]),
    F(Packet).

handle_offer(Offer, HandlerPid) ->
    F = application:get_env(blockchain, sc_packet_handler_offer_fun, fun(_Offer) -> ok end),
    lager:info("Offer: ~p, HandlerPid: ~p", [Offer, HandlerPid]),
    F(Offer).
