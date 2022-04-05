-module(miner_tpm_worker).
-behaviour(gen_server).

-include_lib("public_key/include/public_key.hrl").

-export([start_link/1]).

-export([sign/1, ecdh/1, get_pub_key/0]).

-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
                key_path :: nonempty_string()
                }).

-spec sign(binary()) -> {ok, Signature::binary()} | {error, term()}.
sign(Binary) ->
    gen_server:call(?MODULE, {sign, Binary}).

-spec ecdh(libp2p_crypto:pubkey()) -> {ok, Preseed::binary()} | {error, term()}.
ecdh({ecc_compact, PubKey}) ->
    gen_server:call(?MODULE, {ecdh, PubKey}).

-spec get_pub_key() -> {ok, PubKey::binary()} | {error, term()}.
get_pub_key() ->
    gen_server:call(?MODULE, {get_pub_key}).

-spec(start_link(nonempty_list()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(KeyPath) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [KeyPath], []).


-spec(init(Args :: term()) ->
{ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
{stop, Reason :: term()} | ignore).
init([KeyPath]) ->
    case erlfapi:initialize(null) of
        ok -> {ok, #state{key_path = KeyPath}};
        _Else -> {stop, _Else}
    end.

handle_call({sign, Binary}, _From, State) ->
    Reply = erlfapi:sign(State#state.key_path, null, crypto:hash(sha256, Binary)),
    {reply, Reply, State};

handle_call({ecdh, {#'ECPoint'{point=PubPoint}, _}}, _From, State) ->
    << _:8, X:32/binary, Y:32/binary>> = PubPoint,
    Reply = erlfapi:ecdh_zgen(State#state.key_path, X, Y),
    {reply, Reply, State};

handle_call({get_pub_key}, _From, State) ->
    Reply = case erlfapi:get_public_key_ecc(State#state.key_path) of
            {ok, PubPoint} ->
                CompactKey = {#'ECPoint'{point=PubPoint}, {namedCurve, ?secp256r1}},
                case ecc_compact:is_compact(CompactKey) of
                       {true, _} -> {ok, {ecc_compact, CompactKey}};
                       _Else -> {error, PubPoint}
                end;
            _Else -> _Else
            end,
    {reply, Reply, State};

handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _) ->
    catch erlfapi:finalize().

