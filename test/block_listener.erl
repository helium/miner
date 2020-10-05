-module(block_listener).

-behaviour(gen_server).

%% API
-export([
         start_link/1,
         register_txns/1,
         register_listener/1,
         stop/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        {
         remote,
         regs = [],
         height = 1,
         listeners = []
        }).

%%%===================================================================
%%% API
%%%===================================================================

start_link(RemoteNode) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [RemoteNode], []).

register_txns(Txns) ->
    gen_server:call(?SERVER, {txns, Txns}, infinity).

register_listener(Listener) ->
    gen_server:call(?SERVER, {listener, Listener}, infinity).

stop() ->
    gen_server:call(?SERVER, stop, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([RemoteNode]) ->
    Me = self(),
    ok = ct_rpc:call(RemoteNode, blockchain_event, add_handler, [Me]),
    {ok, #state{remote = RemoteNode}}.

handle_call({txns, Txns}, _From, #state{regs = Regs} = State) ->
    {reply, ok, State#state{regs = Txns ++ Regs}};
handle_call({listener, Listener}, _From, #state{listeners = Listeners} = State) ->
    {reply, ok, State#state{listeners = [Listener | Listeners]}};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, Hash, _Sync, _Ledger}},
            #state{remote = RemoteNode,
                   regs = Regs,
                   height = Height,
                   listeners = Listeners} = State) ->
    Height1 = Height + 1,
    Chain = ct_rpc:call(RemoteNode, blockchain_worker, blockchain, []),
    {ok, Block} = ct_rpc:call(RemoteNode, blockchain, get_block, [Hash, Chain]),
    Txns = blockchain_block:transactions(Block),
    lists:foreach(
      fun(T) ->
              lists:foreach(
                fun(R) ->
                        Type = blockchain_txn:type(T),
                        %% ct:pal("got txn type ~p vs ~p", [Type, R]),
                        case Type == R of
                            true ->
                                [L ! {Type, Height1, T} || L <- Listeners];
                            _ ->
                                ok
                        end
                end,
                Regs)
      end,
      Txns),
    {noreply, State#state{height = Height1}};
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
