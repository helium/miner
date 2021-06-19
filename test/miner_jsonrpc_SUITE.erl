%% @doc This common test suite tests basic JSONRPC functionality

-module(miner_jsonrpc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2,
    all/0
]).

-export([
    info_name_success/1,
    info_height_success/1,
    info_method_not_found_fail/1
]).

-define(HTTPC_PROFILE, miner_ct).
-define(METHOD_NOT_FOUND_CODE, -32601).

-type method() :: binary().
-type params() :: map().
-type request() :: jsx:json_object().
-type response() :: jsx:json_object().
-type parsed_response() :: map().

init_per_suite(Config) ->
    {ok, _Pid} = inets:start(httpc, [{profile, ?HTTPC_PROFILE}]),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0).

end_per_testcase(TestCase, Config) ->
    miner_ct_utils:end_per_testcase(TestCase, Config).

all() ->
    [
        info_name_success,
        info_height_success,
        info_method_not_found_fail
    ].

info_name_success(Config) ->
    [{_Miner, {_TCP, _UCP, JsonRpcPort}} | _Tail] = ?config(ports, Config),
    Req = make_request(<<"info_name">>, []),
    {ok, {_Id, #{<<"name">> := _Name}} = Result} = send_request(JsonRpcPort, Req),
    ct:pal("got ~p", [Result]),
    ok.

info_height_success(Config0) ->
    Config = start_blockchain(Config0),
    Miners = ?config(miners, Config),
    [{_Miner, {_TCP, _UCP, JsonRpcPort}} | _Tail] = ?config(ports, Config),
    miner_ct_utils:wait_for_gte(height, Miners, 3),
    Req = make_request(<<"info_height">>, []),
    {ok, {_Id, #{<<"height">> := H}} = Result} = send_request(JsonRpcPort, Req),
    ?assert(H >= 3),
    ct:pal("got ~p", [Result]),
    ok.

info_method_not_found_fail(Config) ->
    [{_Miner, {_TCP, _UCP, JsonRpcPort}} | _Tail] = ?config(ports, Config),
    Req = make_request(<<"info_strongbad">>, []),
    {error, {_Id, #{<<"code">> := Code}} = Error} = send_request(JsonRpcPort, Req),
    ?assertMatch(?METHOD_NOT_FOUND_CODE, Code),
    ct:pal("got ~p", [Error]),
    ok.

send_request(Port, Request) ->
    Headers = [],
    HTTPOptions = [
        {timeout, 15000},
        {connect_timeout, 1000}
    ],
    Options = [
        {full_result, false},
        {body_format, binary}
    ],
    case
        httpc:request(
            post,
            {make_url(Port), Headers, "application/json-rpc", Request},
            HTTPOptions,
            Options,
            ?HTTPC_PROFILE
        )
    of
        {ok, {200, Body}} -> handle_response(parse_response(Body));
        Other -> ct:fail("Expected 200, got ~p from ~p", [Other, Request])
    end.

-spec make_url(Port :: pos_integer()) -> Url :: string().
make_url(Port) ->
    PortStr = integer_to_list(Port),
    "http://127.0.0.1:" ++ PortStr ++ "/".

-spec make_request(
    Method :: method(),
    Params :: params()
) -> request().
make_request(Method, []) ->
    jsx:encode(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => Method,
            <<"id">> => <<"qux">>
        }
    );
make_request(Method, Params) ->
    jsx:encode(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => Method,
            <<"params">> => Params,
            <<"id">> => <<"baz">>
        }
    ).

-spec parse_response(response()) -> parsed_response().
parse_response(Json) ->
    jsx:decode(Json, [{return_maps, true}]).

-spec handle_response(parsed_response()) -> {ok, Result :: term()} | {error, Error :: term()}.
handle_response(
    #{
        <<"jsonrpc">> := <<"2.0">>,
        <<"error">> := Error
    } = Response
) ->
    case {maps:get(<<"id">>, Response, undefined), Error, maps:is_key(<<"result">>, Response)} of
        {undefined, _Error, true} ->
            {error, invalid_jsonrpc_response};
        {undefined, Error, false} ->
            {error, Error};
        {Id, Error, false} ->
            {error, {Id, Error}};
        {undefined, null, true} ->
            {error, invalid_jsonrpc_response}
    end;
handle_response(
    #{
        <<"jsonrpc">> := <<"2.0">>,
        <<"result">> := Result
    } = Response
) ->
    case {maps:get(<<"id">>, Response, undefined), Result, maps:is_key(<<"error">>, Response)} of
        {undefined, _Result, true} ->
            {error, invalid_jsonrpc_response};
        {undefined, Result, false} ->
            {ok, Result};
        {Id, Result, false} ->
            {ok, {Id, Result}};
        {undefined, null, true} ->
            {error, invalid_jsonrpc_response}
    end;
handle_response(Other) ->
    ct:pal("invalid jsonrpc response: ~p", [Other]),
    {error, invalid_jsonrpc_response}.

start_blockchain(Config) ->
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),
    Curve = ?config(dkg_curve, Config),
    NumConsensusMembers = ?config(num_consensus_members, Config),

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),
    InitialVars = miner_ct_utils:make_vars(Keys, #{}),

    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000)
                       || Addr <- Addresses],
    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/50}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitGen = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
               || {Addr, Loc} <- lists:zip(Addresses, Locations)],
    Txns = InitialVars ++ InitialPayment ++ InitGen,

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, Txns, Addresses,
                                                         NumConsensusMembers, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes),
                                                                 Miners -- DKGCompletedNodes),

    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),


    [ {master_key, {Priv, Pub}},
      {consensus_miners, ConsensusMiners},
      {non_consensus_miners, NonConsensusMiners} | Config ].
