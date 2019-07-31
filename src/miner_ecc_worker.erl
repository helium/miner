-module(miner_ecc_worker).

-behavior(gen_server).

-export([sign/1,
         ecdh/1]).

-export([start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-record(state, {
                ecc_handle :: pid(),
                key_slot :: non_neg_integer(),
                idle_timer = make_ref() :: reference(),
                awake = false
               }).

-spec sign(binary()) -> {ok, Signature::binary()} | {error, term()}.
sign(Binary) ->
    gen_server:call(?MODULE, {sign, Binary}).

-spec ecdh(libp2p_crypto:pubkey()) -> {ok, Preseed::binary()} | {error, term()}.
ecdh({ecc_compact, PubKey}) ->
    gen_server:call(?MODULE, {ecdh, PubKey}).

start_link(KeySlot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [KeySlot], []).


init([KeySlot]) ->
    {ok, ECCHandle} = ecc508:start_link(),
    {ok, #state{ecc_handle=ECCHandle, key_slot=KeySlot}}.


handle_call({sign, Binary}, _From, State) ->
    {Pid, State1} = wake(State),
    Reply = ecc508:sign(Pid, State#state.key_slot, Binary),
    {reply, Reply, idle_timeout(State1)};
handle_call({ecdh, PubKey}, _From, State=#state{ecc_handle=Pid}) ->
    {Pid, State1} = wake(State),
    Reply = ecc508:ecdh(Pid, State#state.key_slot, PubKey),
    {reply, Reply, idle_timeout(State1)};

handle_call(_Msg, _From, State) ->
    lager:warning("unhandled call ~p", [_Msg]),
    {reply, ok, State}.


handle_cast(_Msg, State) ->
    lager:warning("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info(idle_timeout, #state{ecc_handle = Pid} = State) ->
    ecc508:idle(Pid),
    {noreply, State#state{awake = false}};
handle_info(_Msg, State) ->
    lager:warning("unhandled msg ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, State) ->
    catch ecc508:stop(State#state.ecc_handle).

wake(S = #state{awake = true, ecc_handle = Pid}) ->
    {Pid, S};
wake(S = #state{ecc_handle = Pid}) ->
    ecc508:wake(Pid),
    {Pid, S#state{awake = true}}.

idle_timeout(#state{idle_timer = Ref} = S) ->
    erlang:cancel_timer(Ref),
    Timeout = application:get_env(miner, ecc_idle_timeout, 100),
    Ref1 = erlang:send_after(Timeout, self(), idle_timeout),
    S#state{idle_timer = Ref1}.
