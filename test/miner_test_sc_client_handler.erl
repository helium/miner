-module(miner_test_sc_client_handler).

-export([handle_response/1]).

handle_response(Resp) ->
    lager:info("Resp: ~p", [Resp]),
    ok.
