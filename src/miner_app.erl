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

    GlobalOpts = application:get_env(rocksdb, global_opts, []),
    {ok, Cache} = rocksdb:new_cache(lru, 4 * 1024 * 1024),
    {ok, BufferMgr} = rocksdb:new_write_buffer_manager(4 * 1024 * 1024, Cache),
    BBOpts = proplists:get_value(block_based_table_options, GlobalOpts, []),
    Opts1 = proplists:delete(block_based_table_options, GlobalOpts),
    Opts =
        Opts1 ++
            [
                {write_buffer_manager, BufferMgr},
                {block_based_table_options, BBOpts ++ [{block_cache, Cache}]}
            ],
    application:set_env(rocksdb, global_opts, Opts),

    BaseDir = application:get_env(blockchain, base_dir, "data"),
    Filename = filename:join([BaseDir, "follow-mode"]),
    case file:read_file_info(Filename) of
        {ok, _} ->
            application:set_env(blockchain, follow_mode, true);
        _ ->
            ok
    end,

    case miner_sup:start_link() of
        {ok, Pid} ->
            miner_cli_registry:register_cli(),
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
