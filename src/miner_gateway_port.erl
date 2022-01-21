%%%-------------------------------------------------------------------
%% @doc miner gateway service manager
%% Start and monitor the port that runs the external rust-based gateway
%% @end
%%%-------------------------------------------------------------------
-module(miner_gateway_port).

-behaviour(gen_server).

-export([start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2]).

-record(state, {
        keypair,
        port,
        monitor,
        os_pid,
        tcp_port
    }).

start_link(Options) when is_list(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

init([Options]) ->
    Keypair = proplists:get_value(keypair, Options),
    TcpPort = proplists:get_value(port, Options, 4468),

    process_flag(trap_exit, true),

    State = open_gateway_port(Keypair, TcpPort),
    {ok, State}.

handle_call(_Msg, _From, State) ->
    lager:debug("unhandled call ~p by ~p", [_Msg, ?MODULE]),
    {noreply, State}.

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast ~p by ~p", [_Msg, ?MODULE]),
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    lager:warning("gateway-rs process ~p exited with status ~p, restarting", [Port, Status]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(State#state.keypair, State#state.tcp_port),
    ok = miner_gateway_ecc_worker:reconnect(),
    {noreply, NewState};
handle_info({'DOWN', Ref, port, _Pid, Reason}, #state{port = Port, monitor = Ref} = State) ->
    lager:warning("gateway-rs port ~p down with reason ~p, restarting", [Port, Reason]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(State#state.keypair, State#state.tcp_port),
    ok = miner_gateway_ecc_worker:reconnect(),
    {noreply, NewState};
handle_info(_Msg, State) ->
    lager:debug("unhandled info ~p by ~p", [_Msg, ?MODULE]),
    {noreply, State}.

terminate(_, State) ->
    ok = cleanup_port(State).

open_gateway_port(KeyPair, TcpPort) ->
    Args = ["-c", gateway_config_dir(), "server"],
    GatewayEnv0 = [{"GW_API", erlang:integer_to_list(TcpPort)}, {"GW_KEYPAIR", KeyPair}],
    GatewayEnv = case application:get_env(miner, gateway_env) of
                     undefined ->
                         GatewayEnv0;
                     {ok, AddlEnvs} when is_list(AddlEnvs) ->
                         GatewayEnv0 ++ AddlEnvs
                 end,
    PortOpts = [{packet, 2},
                binary,
                use_stdio,
                exit_status,
                {args, Args},
                {env, GatewayEnv}],
    Port = erlang:open_port({spawn_executable, gateway_bin()}, PortOpts),
    Ref = erlang:monitor(port, Port),
    {os_pid, OSPid} = erlang:port_info(Port, os_pid),
    #state{
        keypair = KeyPair,
        monitor = Ref,
        port = Port,
        os_pid = OSPid,
        tcp_port = TcpPort
    }.

cleanup_port(#state{port = Port} = State) ->
    erlang:demonitor(State#state.monitor, [flush]),
    case erlang:port_info(Port) of
        undefined -> true;
        _Result -> erlang:port_close(Port)
    end,
    os:cmd(io_lib:format("kill -9 ~p", [State#state.os_pid])),
    ok.

gateway_config_dir() ->
    code:priv_dir(miner) ++ "/gateway_rs/".
gateway_bin() ->
    gateway_config_dir() ++ "helium_gateway".
