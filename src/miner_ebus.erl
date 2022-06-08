-module(miner_ebus).

-behavior(ebus_object).

-include_lib("ebus/include/ebus.hrl").

-export([send_signal/2]).

-export([start_link/0, start_link/2, init/1, handle_message/3, handle_cast/2, handle_info/2]).

-record(state, {
    connection = undefined :: grpc_client:connection() | undefined,
    grpc_api = false :: boolean()
}).

-define(SERVER, miner_ebus).
-define(SERVICE, 'helium.local.api').

-define(MINER_APPLICATION_NAME, "com.helium.Miner").
-define(MINER_OBJECT_PATH, "/").
-define(MINER_INTERFACE, "com.helium.Miner").
-define(MINER_OBJECT(M), ?MINER_INTERFACE ++ "." ++ M).

-define(MINER_MEMBER_ADD_GW, "AddGateway").
-define(MINER_MEMBER_ASSERT_LOC, "AssertLocation").
-define(MINER_MEMBER_P2P_STATUS, "P2PStatus").
-define(MINER_MEMBER_BLOCK_AGE, "BlockAge").
-define(MINER_MEMBER_HEIGHT, "Height").

-define(MINER_ERROR_BADARGS, "com.helium.Miner.Error.BadArgs").
-define(MINER_ERROR_INTERNAL, "com.helium.Miner.Error.Internal").

start_link() ->
    {ok, Bus} = ebus:system(),
    start_link(Bus, []).

start_link(Bus, Args) ->
    NameOpts = [{replace_existing, true},
                {allow_replacement, true},
                {do_not_queue, true}
               ],
    ok = ebus:request_name(Bus, ?MINER_APPLICATION_NAME, NameOpts),
    ebus_object:start_link(Bus, ?MINER_OBJECT_PATH, ?MODULE, Args, []).

-spec send_signal(string(), string()) -> ok.
send_signal(Signal, Status) ->
    gen_server:cast(?SERVER, {send_signal, Signal, Status}).

init(_Args) ->
    erlang:register(?SERVER, self()),
    {ok, UseGrpc} = application:get_env(miner, gateway_and_mux_enable),
    {ok, #state{ grpc_api = UseGrpc}}.

handle_message(Member, Msg, State = #state{ connection = undefined , grpc_api = true }) ->
    GrpcPort = application:get_env(miner, gateway_api_port, 4468),
    case grpc_client:connect(tcp, "localhost", GrpcPort) of
        {ok, Connection = #{http_connection := Pid}} ->
            erlang:monitor(process, Pid),
            handle_message(Member, Msg, State#state{ connection = Connection});
        {error, Error} ->
            lager:warning("Unable to contact embedded gateway api: ~p", [Error]),
            {reply_error, ?MINER_ERROR_INTERNAL, Member, State}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_ADD_GW) = Member, Msg, State=#state{ grpc_api = false }) ->
    case ebus_message:args(Msg) of
        {ok, [OwnerB58, Fee, StakingFee, PayerB58]} ->
            case (catch blockchain:add_gateway_txn(OwnerB58, PayerB58, Fee, StakingFee)) of
                {ok, TxnBin} ->
                    {reply, [{array, byte}], [TxnBin], State};
                {'EXIT', Why} ->
                    lager:warning("Error requesting add gateway: ~p", [Why]),
                    {reply_error, ?MINER_ERROR_BADARGS, Member, State}
            end;
        {ok, Args} ->
            lager:warning("Invalid add gateway args: ~p", [Args]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State};
        {error, Error} ->
            lager:warning("Invalid add gateway args: ~p", [Error]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_ADD_GW) = Member, Msg, State=#state{ connection = Connection, grpc_api = true }) ->
    case ebus_message:args(Msg) of
        {ok, [OwnerB58, _Fee, _StakingFee, PayerB58]} ->
            case
                call_unary(Connection, add_gateway, #{
                    owner => libp2p_crypto:b58_to_bin(OwnerB58),
                    payer => libp2p_crypto:b58_to_bin(PayerB58),
                    staking_mode => full
                })
            of
                {ok, #{result := #{add_gateway_txn := BinTxn}}} ->
                    {reply, [{array, byte}], [BinTxn], State};
                {error, Error} ->
                    lager:warning("Error requesting add gateway from embedded gateway api: ~p", [Error]),
                    {reply_error, ?MINER_ERROR_INTERNAL, Member, State#state{ connection = undefined }}
            end;
        {ok, Args} ->
            lager:warning("Invalid add gateway args: ~p", [Args]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State};
        {error, Error} ->
            lager:warning("Invalid add gateway args: ~p", [Error]),
            {reply_error, ?MINER_ERROR_BADARGS, Member, State#state{ connection = undefined }}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_ASSERT_LOC) = Member, _Msg, State) ->
    lager:warning("Assert_loc deprecated; miners now obtain loc data on-chain", []),
    {reply_error, ?MINER_ERROR_BADARGS, Member, State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_P2P_STATUS), _Msg, State=#state{ grpc_api = false }) ->
    Status = miner:p2p_status(),
    {reply, [{array, {struct, [string, string]}}], [Status], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_P2P_STATUS) = _Member, _, State=#state{ connection = Connection, grpc_api = true }) ->
    case call_unary(Connection, height, #{}) of
        {ok, #{result := #{height := Height}}} ->
            Status = [{"connected", "yes"}, {"height", integer_to_list(Height)}],
            {reply, [{array, {struct, [string, string]}}], [Status], State};
        {error, Reason} ->
            lager:warning("Error requesting status from embedded gateway api: ~p", [Reason]),
            {reply, [{array, {struct, [string, string]}}], [[{"connected", "no"}]], State#state{ connection = undefined }}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_BLOCK_AGE), _Msg, State=#state{ grpc_api = false }) ->
    Age = miner:block_age(),
    {reply, [int32], [Age], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_BLOCK_AGE) = Member, _Msg, State=#state{ connection = Connection, grpc_api = true }) ->
    case call_unary(Connection, height, #{}) of
        {ok, #{result := #{block_age := Age}}} ->
            {reply, [uint64], [Age], State};
        {error, Reason} ->
            lager:warning("Error requesting block age from embedded gateway api: ~p", [Reason]),
            {reply_error, ?MINER_ERROR_INTERNAL, Member, State#state{ connection = undefined }}
    end;
handle_message(?MINER_OBJECT(?MINER_MEMBER_HEIGHT), _Msg, State=#state{ grpc_api = false }) ->
    Chain = blockchain_worker:blockchain(),
    {ok, Height} = blockchain:height(Chain),
    {reply, [int32], [Height], State};
handle_message(?MINER_OBJECT(?MINER_MEMBER_HEIGHT) = Member, _Msg, State=#state{ connection = Connection, grpc_api = true }) ->
    case call_unary(Connection, height, #{}) of
        {ok, #{result := #{height := Height}}} ->
            {reply, [uint64], [Height], State};
        {error, Reason} ->
            lager:warning("Error requesting height from embedded gateway api: ~p", [Reason]),
            {reply_error, ?MINER_ERROR_INTERNAL, Member, State#state{ connection = undefined }}
    end;
handle_message(Member, _Msg, State) ->
    lager:warning("Unhandled dbus message ~p", [Member]),
    {reply_error, ?DBUS_ERROR_NOT_SUPPORTED, Member, State}.

handle_cast({send_signal, Signal, Status}, State) ->
    {noreply, State, {signal, ?MINER_OBJECT_PATH, ?MINER_INTERFACE, Signal, [string], [Status]}};
handle_cast(_Msg, State) ->
    lager:warning("unhandled msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Info}, State = #state{ connection = #{ http_connection := Pid }}) ->
    lager:warning("Gateway api grpc connection down; restarting", []),
    {noreply, State#state{ connection = undefined }};
handle_info(_Msg, State) ->
    lager:info("unhandled info message ~p", [_Msg]),
    {noreply, State}.

call_unary(Connection, Method, Arguments) ->
    grpc_client:unary(Connection, Arguments, ?SERVICE, Method, local_miner_client_pb, [{timeout, 5000}]).
