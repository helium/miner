%%%-------------------------------------------------------------------
%% @doc miner public API
%% @end
%%%-------------------------------------------------------------------

-module(miner_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->

    persistent_term:put(ospid, os:getpid()),

    Follow =
        %% validator as the default here because it's a safer failure mode.
        case application:get_env(miner, mode, validator) of
            %% follow mode defaults to false
            validator -> false;
            gateway ->
                %% check touchfile, since some people are using it
                BaseDir = application:get_env(blockchain, base_dir, "data"),
                Filename = filename:join([BaseDir, "validate-mode"]),
                case file:read_file_info(Filename) of
                    {ok, _} -> false;
                    _ -> true
                end
        end,

    application:set_env(blockchain, follow_mode, Follow),

    case miner_sup:start_link() of
        {ok, Pid} ->
            miner_cli_registry:register_cli(),
            {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
