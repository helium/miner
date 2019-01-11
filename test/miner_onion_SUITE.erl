-module(miner_onion_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->

    application:ensure_all_started(lager),

    {ok, LSock} = gen_tcp:listen(0, [{active, false}, binary, {packet, 2}]),

    {ok, Port} = inet:port(LSock),

    {ok, PrivateKey, CompactKey} = ecc_compact:generate_key(),
    {ok, _Server} = miner_onion_server:start_link("127.0.0.1", Port, CompactKey, PrivateKey, self()),
    {ok, Sock} = gen_tcp:accept(LSock),

    Data = <<1, 2, 3>>,
    Onion = miner_onion_server:construct_onion([{Data, CompactKey}]),

    meck:new(miner_onion_server, [passthrough]),
    meck:expect(miner_onion_server, send_receipt, fun(_IV, Data0) ->
        ?assertEqual(Data, Data0),
        ok
    end),

    ok = gen_tcp:send(Sock, <<16#81, Onion/binary>>),
    {ok, _} = gen_tcp:recv(Sock, 0),

    ?assert(meck:validate(miner_onion_server)),
    meck:unload(miner_onion_server),
    ok.