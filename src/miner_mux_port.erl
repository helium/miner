%%%-------------------------------------------------------------------
%% @doc miner gwmp-mux service manager
%% Start and monitor the port that runs the external rust-based semtech
%% gwmp mux service
%% @end
%%%-------------------------------------------------------------------
-module(miner_mux_port).

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
    client_ports,
    host_port,
    monitor,
    os_pid,
    port
}).

start_link(Options) when is_list(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

init([Options]) ->
    HostTcpPort = proplists:get_value(host_port, Options, 1680),
    ClientTcpPorts = proplists:get_value(client_ports, Options, [1681, 1682]),

    process_flag(trap_exit, true),

    State = open_mux_port(HostTcpPort, ClientTcpPorts),
    {ok, State}.

handle_call(_Msg, _From, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    lager:warning("gwmp-mux process ~p exited with status ~p, restart", [Port, Status]),
    ok = cleanup_port(State),
    NewState = open_mux_port(State#state.host_port, State#state.client_ports),
    {noreply, NewState};
handle_info({Port, {data, LogMsg}}, #state{port = Port} = State) ->
    Lines = binary:split(LogMsg, <<"\n">>, [global]),
    [dispatch_port_logs(Line) || Line <- Lines],
    {noreply, State};
handle_info({'DOWN', Ref, port, _Pid, Reason}, #state{port = Port, monitor = Ref} = State) ->
    lager:warning("gwmp-mux port ~p down with reason ~p, restarting", [Port, Reason]),
    ok = cleanup_port(State),
    NewState = open_mux_port(State#state.host_port, State#state.client_ports),
    {noreply, NewState};
handle_info(_Msg, State) ->
    lager:debug("unhandled info ~p", [_Msg]),
    {noreply, State}.

terminate(_, State) ->
    ok = cleanup_port(State).

open_mux_port(HostTcpPort, ClientTcpPorts) when is_list(ClientTcpPorts) ->
    ClientList = client_address_list(ClientTcpPorts),
    lager:info("client list ~p", [ClientList]),
    Args = ["--host", erlang:integer_to_list(HostTcpPort)] ++ ClientList,
    lager:info("mux args list ~p", [Args]),
    PortOpts = [
        binary,
        use_stdio,
        exit_status,
        {args, Args}
    ],
    Port = erlang:open_port({spawn_executable, mux_bin()}, PortOpts),
    Ref = erlang:monitor(port, Port),
    {os_pid, OSPid} = erlang:port_info(Port, os_pid),
    #state{
        client_ports = ClientTcpPorts,
        host_port = HostTcpPort,
        os_pid = OSPid,
        monitor = Ref,
        port = Port
    }.

cleanup_port(#state{port = Port} = State) ->
    erlang:demonitor(State#state.monitor, [flush]),
    case erlang:port_info(Port) of
        undefined -> true;
        _Result -> erlang:port_close(Port)
    end,
    os:cmd(io_lib:format("kill -9 ~p", [State#state.os_pid])),
    ok.

mux_bin() ->
    code:priv_dir(miner) ++ "/semtech_udp/gwmp-mux".

client_address_list(ClientTcpPorts) when is_list(ClientTcpPorts) ->
    lists:flatmap(
        fun(TcpPort) ->
            ["--client", lists:flatten(io_lib:format("127.0.0.1:~p", [TcpPort]))]
        end,
        ClientTcpPorts
    ).

dispatch_port_logs(Line) ->
    case Line of
        <<" TRACE ", Statement/binary>> ->
            lager:debug("***semtech-udp*** ~s", [Statement]);
        <<" DEBUG ", Statement/binary>> ->
            lager:debug("***semtech-udp*** ~s", [Statement]);
        <<" INFO ", Statement/binary>> ->
            lager:info("***semtech-udp*** ~s", [Statement]);
        <<" WARN ", Statement/binary>> ->
            lager:warning("***semtech-udp*** ~s", [Statement]);
        <<" ERROR ", Statement/binary>> ->
            lager:error("***semtech-udp*** ~s", [Statememnt]);
        _ -> lager:debug("unhandled info ~p", [Line])
    end.
