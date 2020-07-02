-module(miner_test_sc_client_handler).

-export([handle_response/1, handle_purchase/1]).

handle_response(Resp) ->
    lager:info("Resp: ~p", [Resp]),
    ok.

handle_purchase(Purchase) ->
    lager:info("Purchase: ~p", [Purchase]),
    ok.
