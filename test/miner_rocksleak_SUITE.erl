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

-define(LEN, 50000).

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
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter} = rocksdb:transaction_iterator(DB, Txn, OneCF,
                                              [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter, rocksdb:iterator_move(Iter, first)),

    ok = rocksdb:transaction_commit(Txn),
    {ok, Txn1} = rocksdb:transaction(DB, [{write, sync}]),

    VTwo = iolist_to_binary(lists:duplicate(100, <<"one">>)),
    [begin
         ok = rocksdb:transaction_put(Txn1, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn1, OneCF, <<"one_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter1} = rocksdb:transaction_iterator(DB, Txn1, OneCF,
                                              [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter1, rocksdb:iterator_move(Iter1, first)),

    ok = rocksdb:transaction_commit(Txn1),

    {ok, TwoCF} = rocksdb:create_column_family(DB, "two", OpenOpts),

    ok = rocksdb:drop_column_family(OneCF),
    ok = rocksdb:destroy_column_family(OneCF),

    {ok, Txn2} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn2, <<"def_", (integer_to_binary(I))/binary>>, VOne),
         ok = rocksdb:transaction_put(Txn2, TwoCF, <<"two_", (integer_to_binary(I))/binary>>, VOne)
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter2} = rocksdb:transaction_iterator(DB, Txn2, TwoCF,
                                               [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter2, rocksdb:iterator_move(Iter2, first)),

    ok = rocksdb:transaction_commit(Txn2),
    {ok, Txn3} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn3, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn3, TwoCF, <<"two_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter3} = rocksdb:transaction_iterator(DB, Txn3, TwoCF,
                                               [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter3, rocksdb:iterator_move(Iter3, first)),

    ok = rocksdb:transaction_commit(Txn3),

    {ok, ThreeCF} = rocksdb:create_column_family(DB, "three", OpenOpts),

    ok = rocksdb:drop_column_family(TwoCF),
    ok = rocksdb:destroy_column_family(TwoCF),


    {ok, Txn4} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn4, <<"def_", (integer_to_binary(I))/binary>>, VOne),
         ok = rocksdb:transaction_put(Txn4, ThreeCF, <<"three_", (integer_to_binary(I))/binary>>, VOne)
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter4} = rocksdb:transaction_iterator(DB, Txn4, ThreeCF,
                                               [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter4, rocksdb:iterator_move(Iter4, first)),

    ok = rocksdb:transaction_commit(Txn4),

    {ok, Txn5} = rocksdb:transaction(DB, [{write, sync}]),

    [begin
         ok = rocksdb:transaction_put(Txn5, <<"def_", (integer_to_binary(I))/binary>>, VTwo),
         ok = rocksdb:transaction_put(Txn5, ThreeCF, <<"three_", (integer_to_binary(I))/binary>>, VTwo)
     end || I <- lists:seq(1, ?LEN)],

    {ok, Iter5} = rocksdb:transaction_iterator(DB, Txn5, ThreeCF,
                                               [{iterate_upper_bound, <<"one_123912873129873123">>}]),

    iterate(Iter5, rocksdb:iterator_move(Iter5, first)),

    ok = rocksdb:transaction_commit(Txn5),

    rocksdb:close(DB),

    io:fwrite(standard_error, "finished iteration ~p~n", [N]),
    rocksloop(N - 1).

iterate(I, {error, _}) ->
    rocksdb:iterator_close(I);
iterate(I, {ok, _, _}) ->
    iterate(I, rocksdb:iterator_move(I, next)).

