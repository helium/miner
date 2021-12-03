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
    RocksDBCacheSize = application:get_env(miner, rocksdb_cache_size, 8),
    RocksDBWriteBufferSize = application:get_env(miner, rocksdb_write_buffer_size, 8),
    {ok, Cache} = rocksdb:new_cache(lru, RocksDBCacheSize * 1024 * 1024),
    {ok, BufferMgr} = rocksdb:new_write_buffer_manager(RocksDBWriteBufferSize * 1024 * 1024, Cache),
    BBOpts = proplists:get_value(block_based_table_options, GlobalOpts, []),
    Opts1 = proplists:delete(block_based_table_options, GlobalOpts),
    Opts = Opts1 ++ [{write_buffer_manager, BufferMgr},
                     {block_based_table_options,
                      BBOpts ++ [{block_cache, Cache}]}],
    application:set_env(rocksdb, global_opts, Opts),

    Follow =
        %% validator as the default here because it's a safer failure mode.
        case application:get_env(miner, mode, validator) of
            %% follow mode defaults to false for miner validator mode
            validator -> false;
            gateway ->
                case application:get_env(blockchain, follow_mode) of
                    undefined ->
                        %% check touchfile, since some people are using it
                        BaseDir = application:get_env(blockchain, base_dir, "data"),
                        Filename = filename:join([BaseDir, "validate-mode"]),
                        case file:read_file_info(Filename) of
                            {ok, _} -> false;
                            _ -> true
                        end;
                    {ok, FollowMode} ->
                        %% blockchain follow_mode was already set, honor that
                        FollowMode
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
