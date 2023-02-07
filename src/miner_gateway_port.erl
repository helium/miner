%%%-------------------------------------------------------------------
%% @doc miner gateway service manager
%% Start and monitor the port that runs the external rust-based gateway
%% @end
%%%-------------------------------------------------------------------
-module(miner_gateway_port).

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
    keypair,
    transport=tcp,
    host="localhost",
    port,
    monitor,
    os_pid,
    tcp_port=4468,
    udp_port
}).

-define(CONNECT_RETRY_WAIT, 100).
-define(CONNECT_ATTEMPTS, 5).
-define(HEALTHCHECK_INTERVAL, 600000).
-define(HEALTHCHECK_TIMEOUT, 60000).

start_link(Options) when is_list(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

init([Options]) ->
    Keypair = proplists:get_value(keypair, Options),
    TcpPort = proplists:get_value(api_port, Options, 4468),
    UdpPort = proplists:get_value(radio_port, Options, 1682),
    Host = proplists:get_value(host, Options, "127.0.0.1"),
    Transport = proplists:get_value(transport, Options, tcp),

    process_flag(trap_exit, true),

    erlang:send_after(?HEALTHCHECK_INTERVAL, self(), gw_healthcheck),
    State = open_gateway_port(Keypair, Transport, Host, UdpPort, TcpPort),
    {ok, State}.

handle_call(_Msg, _From, State) ->
    lager:debug("unhandled call ~p", [_Msg]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast ~p", [_Msg]),
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    lager:warning("gateway-rs process ~p exited with status ~p, restarting", [Port, Status]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(
                   State#state.keypair,
                   State#state.transport,
                   State#state.host,
                   State#state.udp_port,
                   State#state.tcp_port),
    ok = miner_gateway_ecc_worker:reconnect(),
    {noreply, NewState};
handle_info({Port, {data, LogMsg}}, #state{port = Port} = State) ->
    Lines = binary:split(LogMsg, <<"\n">>, [global]),
    [dispatch_port_logs(Line) || Line <- Lines],
    {noreply, State};
handle_info({'DOWN', Ref, port, _Pid, Reason}, #state{port = Port, monitor = Ref} = State) ->
    lager:warning("gateway-rs port ~p down with reason ~p, restarting", [Port, Reason]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(
                   State#state.keypair,
                   State#state.transport,
                   State#state.host,
                   State#state.udp_port,
                   State#state.tcp_port),
    ok = miner_gateway_ecc_worker:reconnect(),
    {noreply, NewState};
handle_info(gw_healthcheck, State) ->
    case healthcheck_cmd() of
        {0, _Output} ->
            erlang:send_after(?HEALTHCHECK_INTERVAL, self(), gw_healthcheck),
            {noreply, State};
        {_Exit, Reason} ->
            ok = cleanup_port(State),
            lager:error("embedded helium_gateway healthcheck failed with reason: ~p", [Reason]),
            NewState = open_gateway_port(
                         State#state.keypair,
                         State#state.transport,
                         State#state.host,
                         State#state.udp_port,
                         State#state.tcp_port),
            ok = miner_gateway_ecc_worker:reconnect(),
            {noreply, NewState}
    end;
handle_info(_Msg, State) ->
    lager:debug("unhandled info ~p", [_Msg]),
    {noreply, State}.

terminate(_, State) ->
    ok = cleanup_port(State).

open_gateway_port(KeyPair, Transport, Host, UdpPort, TcpPort) ->
    Args = ["-c", gateway_config_dir(), "--stdin", "server"],
    GatewayEnv0 = [{"GW_API", erlang:integer_to_list(TcpPort)},
                   {"GW_KEYPAIR", KeyPair},
                   {"GW_LISTEN", lists:flatten(io_lib:format("~s:~p", [Host, UdpPort]))}],
    GatewayEnv =
        case application:get_env(miner, gateway_env) of
            undefined ->
                GatewayEnv0;
            {ok, AddlEnvs} when is_list(AddlEnvs) ->
                GatewayEnv0 ++ AddlEnvs
        end,
    PortOpts = [
        binary,
        use_stdio,
        exit_status,
        {args, Args},
        {env, GatewayEnv}
    ],
    Port = erlang:open_port({spawn_executable, gateway_bin()}, PortOpts),
    Ref = erlang:monitor(port, Port),
    {os_pid, OSPid} = erlang:port_info(Port, os_pid),

    ok = verify_grpc_connect(Transport, Host, TcpPort, ?CONNECT_ATTEMPTS),

    #state{
        keypair = KeyPair,
        monitor = Ref,
        port = Port,
        os_pid = OSPid,
        transport = Transport,
        host = Host,
        tcp_port = TcpPort,
        udp_port = UdpPort
    }.

cleanup_port(#state{port = Port} = State) ->
    erlang:demonitor(State#state.monitor, [flush]),
    case erlang:port_info(Port) of
        undefined -> true;
        _Result -> erlang:port_close(Port)
    end,
    os:cmd(io_lib:format("kill -9 ~p", [State#state.os_pid])),
    ok.

-spec healthcheck_cmd() -> {non_neg_integer(), iolist() | timeout}.
healthcheck_cmd() ->
    Command = gateway_bin() ++ " -c " ++ gateway_config_dir() ++ " info",
    PortOpts = [stream, exit_status, use_stdio, stderr_to_stdout, in, eof],
    PortId = erlang:open_port({spawn, Command}, PortOpts),
    healthcheck_cmd_collect(PortId, []).

healthcheck_cmd_collect(PortId, Data) ->
    receive
        {PortId, {data, D}} ->
            healthcheck_cmd_collect(PortId, [D | Data]);
        {PortId, eof} ->
            erlang:port_close(PortId),
            receive
                {PortId, {exit_status, ExitCode}} ->
                    {ExitCode, lists:reverse(Data)}
            end
    after
        ?HEALTHCHECK_TIMEOUT ->
            erlang:port_close(PortId),
            receive
                {PortId, {exit_status, ExitCode}} ->
                    {ExitCode, lists:reverse(Data)}
            after
                0 ->
                    {1, timeout}
            end
    end.

gateway_config_dir() ->
    code:priv_dir(miner) ++ "/gateway_rs/".
gateway_bin() ->
    gateway_config_dir() ++ "helium_gateway".

dispatch_port_logs(Line) ->
    case Line of
        <<" TRACE ", Statement/binary>> ->
            lager:debug("[ gateway-rs ] ~s", [Statement]);
        <<" DEBUG ", Statement/binary>> ->
            lager:debug("[ gateway-rs ] ~s", [Statement]);
        <<" INFO ", Statement/binary>> ->
            lager:info("[ gateway-rs ] ~s", [Statement]);
        <<" WARN ", Statement/binary>> ->
            lager:warning("[ gateway-rs ] ~s", [Statement]);
        <<" ERROR ", Statement/binary>> ->
            lager:error("[ gateway-rs ] ~s", [Statement]);
        _ -> lager:debug("unhandled info ~p", [Line])
    end.

verify_grpc_connect(_Transport, _Host, _TcpPort, 0) ->
    lager:error("~s failed to connect to gateway ~s://~s:~p", [?MODULE, _Transport, _Host, _TcpPort]),
    {error, retries_exceeded};
verify_grpc_connect(Transport, Host, TcpPort, Tries) ->
    case grpc_client:connect(Transport, Host, TcpPort) of
        {ok, Connection} ->
            lager:debug("~s connected to gateway grpc ~s://~s:~p", [?MODULE, Transport, Host, TcpPort]),
            catch grpc_client:stop_connection(Connection),
            ok;
        _ ->
            lager:warning("~s grpc connection to gateway failed; retrying...", [?MODULE]),
            timer:sleep(?CONNECT_RETRY_WAIT),
            verify_grpc_connect(Transport, Host, TcpPort, Tries - 1)
    end.
