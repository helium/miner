%%%-------------------------------------------------------------------
%% @doc miner gateway ecc worker
%% Interface to the rust-based gateway service over grpc
%% @end
%%%-------------------------------------------------------------------
-module(miner_gateway_ecc_worker).

-behaviour(gen_server).

-export([
    pubkey/0,
    ecdh/1,
    sign/1,
    reconnect/0
]).

-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-record(state, {
    connection :: pid(),
    host = "localhost" :: string(),
    port = 4468 :: integer(),
    transport = tcp :: tcp | ssl
}).

-define(CONNECT_RETRY_WAIT, 100).
-define(RETRY_WAIT, 10).
-define(MAX_RETRIES, 10).
%% Make the call timeout quite long since this worker has to process
%% all signing requests for the system
-define(CALL_TIMEOUT, (?MAX_RETRIES * ?RETRY_WAIT) * 10).

%% Retrieve the public key for the ecc chip from the rust gateway and
%% deserialize it from the binary returned
-spec pubkey() -> {ok, libp2p_crypto:pubkey()} | {error, term()}.
pubkey() ->
    gen_server:call(?MODULE, pubkey, ?CALL_TIMEOUT).

%% Pass a binary to the rust gateway for signing and returned the signed binary
-spec sign(binary()) -> {ok, Signature :: binary() | {error, term()}}.
sign(Binary) ->
    gen_server:call(?MODULE, {sign, Binary}, ?CALL_TIMEOUT).

%% Pass an ecc public key to the rust gateway and return a point on the
%% eliptic curve as a binary
-spec ecdh(libp2p_crypto:pubkey()) -> {ok, Preseed :: binary()} | {error, term()}.
ecdh({ecc_compact, _Bin} = PubKey) ->
    gen_server:call(?MODULE, {ecdh, PubKey}, ?CALL_TIMEOUT).

%% Trigger a reconnect of the grpc_client connection
-spec reconnect() -> ok.
reconnect() ->
    gen_server:cast(?MODULE, reconnect).

start_link(Options) when is_list(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

init([Options]) ->
    Transport = proplists:get_value(transport, Options, tcp),
    Host = proplists:get_value(host, Options, "localhost"),
    Port = proplists:get_value(port, Options, 4468),
    {ok, Connection} = grpc_connect(Transport, Host, Port),
    {ok, #state{connection = Connection, transport = Transport, host = Host, port = Port}}.

handle_call(pubkey, _From, State = #state{connection = Connection}) ->
    Reply =
        case rpc(Connection, #{}, pubkey, ?MAX_RETRIES) of
            {ok, #{address := Pubkey}} ->
                libp2p_crypto:bin_to_pubkey(Pubkey);
            Error ->
                Error
        end,
    {reply, {ok, Reply}, State};
handle_call({sign, Binary}, _From, State = #state{connection = Connection}) ->
    Reply =
        case rpc(Connection, #{data => Binary}, sign, ?MAX_RETRIES) of
            {ok, #{signature := Signature}} -> Signature;
            Error -> Error
        end,
    {reply, {ok, Reply}, State};
handle_call({ecdh, PubKey}, _From, State = #state{connection = Connection}) ->
    Reply =
        case
            rpc(Connection, #{address => libp2p_crypto:pubkey_to_bin(PubKey)}, ecdh, ?MAX_RETRIES)
        of
            {ok, #{secret := Secret}} -> Secret;
            Error -> Error
        end,
    {reply, {ok, Reply}, State};
handle_call(_Msg, _From, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(reconnect, State) ->
    lager:info("reconnecting ~p grpc client", [?MODULE]),
    ok = grpc_disconnect(State#state.connection),
    {ok, NewConnection} = grpc_connect(State#state.transport, State#state.host, State#state.port),
    {noreply, State#state{connection = NewConnection}};
handle_cast(_Msg, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:debug("unhandled info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    grpc_disconnect(State#state.connection).

rpc(_Connection, _Req, _RPC, 0) ->
    lager:error("failed to execute grpc request ~p", [_Req]),
    {error, retries_exceeded};
rpc(Connection, Req, RPC, Tries) ->
    Timeout = rpc_timeout(Tries),
    case
        grpc_client:unary(Connection, Req, 'helium.local.api', RPC, local_miner_client_pb, [
            {timeout, Timeout}
        ])
    of
        {ok, #{result := Result, trailers := #{<<"grpc-status">> := <<"0">>}}} ->
            {ok, Result};
        {error, #{error_type := timeout}} ->
            {error, timeout};
        {error, #{error_type := ErrType, status_message := Message}} ->
            Retries = Tries - 1,
            lager:warning("grpc request failed with ~p for reason ~p; retrying ~p times", [
                ErrType, Message, Retries
            ]),
            timer:sleep(?RETRY_WAIT),
            rpc(Connection, Req, RPC, Retries)
    end.

rpc_timeout(Tries) ->
    case (Tries * ?RETRY_WAIT * 10) - 1 of
        Timeout when Timeout < 0 -> 0;
        Timeout -> Timeout
    end.

grpc_connect(Transport, Host, Port) ->
    case grpc_client:connect(Transport, Host, Port) of
        {ok, Connection} ->
            lager:debug("~s connected to gateway grpc at ~s://~s:~p", [?MODULE, Transport, Host, Port]),
            {ok, Connection};
        _ ->
            lager:warning("~s grpc connection to gateway failed; retrying...", [?MODULE]),
            timer:sleep(?CONNECT_RETRY_WAIT),
            grpc_connect(Transport, Host, Port, Tries - 1)
    end.

grpc_disconnect(GrpcConnection) ->
    catch grpc_client:stop_connection(GrpcConnection),
    ok.
