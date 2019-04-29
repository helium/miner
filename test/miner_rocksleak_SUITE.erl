%%%-------------------------------------------------------------------
%%% @author Evan Vigil-McClanahan <mcclanhan@gmail.com>
%%% @copyright (C) 2019, Evan Vigil-McClanahan
%%% @doc
%%%
%%% @end
%%% Created : 29 Apr 2019 by Evan Vigil-McClanahan <mcclanhan@gmail.com>
%%%-------------------------------------------------------------------
-module(miner_rocksleak_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

all() ->
    [my_test_case].

my_test_case() ->
    [].

my_test_case(_Config) ->
    rocksloop(100000),

    ok.

rocksloop(0) ->
    ok;
rocksloop(N) ->
    DataDir = "datadir_" ++ integer_to_list(N),
    OpenOpts = [{max_open_files, 1024},
                {max_log_file_size, 100*1024*1024},
                {merge_operator, {bitset_merge_operator, 16}},
                {total_threads,4},
                {max_background_jobs,2},
                {max_background_compactions,2},
                {max_open_files,128},
                {compaction_style,universal}],

    {ok, DB, [Def]} =
        rocksdb:open_optimistic_transaction_db(DataDir,
                                               [{create_if_missing, true}] ++ OpenOpts,
                                               [ {CF, OpenOpts}
                                                 || CF <- ["default"] ]),
    {ok, OneCF} = rocksdb:create_column_family(DB, "one", OpenOpts),

    {ok, Txn} = rocksdb:transaction(DB, [{write, sync}]),
    %% create a new CF
    VOne = iolist_to_binary(lists:duplicate(100, <<"one">>)),

    [begin
         ok = rocksdb:transaction_put(Txn, <<"def_", (integer_to_binary(I))/binary>>, VOne),
         ok = rocksdb:transaction_put(Txn, OneCF, <<"one_", (integer_to_binary(I))/binary>>, VOne)
     end || I <- lists:seq(1, 1000)],

    ok = rocksdb:transaction_commit(Txn),
    {ok, Txn1} = rocksdb:transaction(DB, [{write, sync}]),

    VTwo = iolist_to_binary(lists:duplicate(100, <<"one">>)),
    [begin
         ok = rocksdb:transaction_put(Txn1, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn1, OneCF, <<"one_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, 1000)],

    ok = rocksdb:transaction_commit(Txn1),

    {ok, TwoCF} = rocksdb:create_column_family(DB, "two", OpenOpts),

    ok = rocksdb:drop_column_family(OneCF),
    ok = rocksdb:destroy_column_family(OneCF),

    {ok, Txn2} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn2, <<"def_", (integer_to_binary(I))/binary>>, VOne),
         ok = rocksdb:transaction_put(Txn2, TwoCF, <<"two_", (integer_to_binary(I))/binary>>, VOne)
     end || I <- lists:seq(1, 1000)],

    ok = rocksdb:transaction_commit(Txn2),
    {ok, Txn3} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn3, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn3, TwoCF, <<"two_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, 1000)],

    ok = rocksdb:transaction_commit(Txn3),

    {ok, ThreeCF} = rocksdb:create_column_family(DB, "three", OpenOpts),

    ok = rocksdb:drop_column_family(TwoCF),
    ok = rocksdb:destroy_column_family(TwoCF),


    {ok, Txn4} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn4, <<"def_", (integer_to_binary(I))/binary>>, VOne),
         ok = rocksdb:transaction_put(Txn4, ThreeCF, <<"three_", (integer_to_binary(I))/binary>>, VOne)
     end || I <- lists:seq(1, 1000)],

    ok = rocksdb:transaction_commit(Txn4),
    {ok, Txn5} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn5, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn5, ThreeCF, <<"three_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, 1000)],
    ok = rocksdb:transaction_commit(Txn5),

    rocksdb:close(DB),
    rocksloop(N - 1).






