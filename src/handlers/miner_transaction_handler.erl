%%%-------------------------------------------------------------------
%% @doc
%% == Miner Transaction Stream Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_transaction_handler).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4
    ,client/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3
    ,handle_data/3
]).

-record(state, {
          group :: pid()
         }).

client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(client, _Conn, [_Parent]) ->
    {ok, #state{}};
init(server, _Conn, [_Path, _Parent, Group]) ->
    %lager:info("txn handler accepted connection~n"),
    {ok, #state{group=Group}}.

handle_data(client, _Data, State) ->
    {stop, normal, State};
handle_data(server, Data, State=#state{group=Group}) ->
    case binary_to_term(Data) of
        {TxnType, Txn} ->
            lager:info("Got ~p type transaction: ~p", [TxnType, Txn]),
            ok = libp2p_group_relcast:handle_input(Group, Txn);
        _ ->
            lager:notice("transaction_handler got unknown data")
    end,
    {stop, normal, State}.
