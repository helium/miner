%%%-------------------------------------------------------------------
%% @doc miner gateway service manager
%% Start and monitor the port that runs the external rust-based gateway
%% @end
%%%-------------------------------------------------------------------
-module(miner_gateway_port).

-behaviour(gen_server).

-export([get_os_pid/0]).
-export([start_link/0,
         init/1,
         handle_call/3,
         handle_info/2,
         terminate/2]).

-record(state, {
        port,
        monitor,
        os_pid
    }).

get_os_pid() ->
    gen_server:call(?MODULE, os_pid).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_Opts) ->
    process_flag(trap_exit, true),
    State = open_gateway_port(),
    {ok, State}.

handle_call(os_pid, _From, State) ->
    {reply, State#state.os_pid, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    lager:warning("gateway-rs process ~p exited with status ~p, restarting", [Port, Status]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(),
    {noreply, NewState};
handle_info({'DOWN', Ref, port, _Pid, Reason}, #state{port = Port, monitor = Ref} = State) ->
    lager:warning("gateway-rs port ~p down with reason ~p, restarting", [Port, Reason]),
    ok = cleanup_port(State),
    NewState = open_gateway_port(),
    {noreply, NewState};
handle_info(_Msg, State) ->
    lager:info("unhandled call ~p by ~p", [_Msg, ?MODULE]),
    {noreply, State}.

terminate(_, State) ->
    ok = cleanup_port(State).

open_gateway_port() ->
    Args = ["-c", gateway_config_dir(), "server"],
    Key = case application:get_env(miner, gateway_keypair) of
              undefined ->
                  os:getenv("GW_KEYPAIR", "ecc://i2c-1:96&slot=0");
              {ok, Keypair} ->
                  Keypair
          end,
    GatewayEnv0 = [{"GW_KEYPAIR", Key}],
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
    OSPid = erlang:port_info(Port, os_pid),
    #state{port = Port, monitor = Ref, os_pid = OSPid}.

cleanup_port(State) ->
    erlang:demonitor(State#state.monitor),
    erlang:port_close(State#state.port),
    os:cmd(io_lib:format("kill -9 ~p", [State#state.os_pid])),
    ok.

gateway_config_dir() ->
    code:priv_dir(miner) ++ "/gateway_rs/".
gateway_bin() ->
    gateway_config_dir() ++ "helium_gateway".
