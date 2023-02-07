-module(miner_gateway_stub_ecc_worker).
-include_lib("public_key/include/public_key.hrl").

-behaviour(gen_server).

-export([
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).



-record(state, {
          key = libp2p_crypto:generate_keys(ecc_compact)
         }).


start_link(Options) when is_list(Options) ->
    %% register as the miner_gateway_ecc_worker
    gen_server:start_link({local, miner_gateway_ecc_worker}, ?MODULE, [Options], []).

init(_Options) ->
    {ok, #state{}}.

handle_call(pubkey, _From, State = #state{key = #{public := Public}}) ->
    {reply, {ok, Public}, State};
handle_call({sign, Binary}, _From, State = #state{key = #{secret := Secret}}) ->
    Reply = public_key:sign(Binary, sha256, Secret),
    {reply, {ok, Reply}, State};
handle_call({ecdh, {ecc_compact, {PubKey, {namedCurve, ?secp256r1}}}}, _From, State = #state{key = #{secret := Secret}}) ->
    Reply = public_key:compute_key(PubKey, Secret),
    {reply, {ok, Reply}, State};
handle_call(_Msg, _From, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(reconnect, State) ->
    {noreply, State};
handle_cast(_Msg, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_info(_Msg, State) ->
    lager:debug("unhandled info ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

