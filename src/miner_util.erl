%%%-------------------------------------------------------------------
%% @doc miner_util
%% @end
%%%-------------------------------------------------------------------
-module(miner_util).

-export([load_block_from_file/1]).

load_block_from_file(FileName) ->
    case file:read_file(FileName) of
        {ok, <<>>} ->
            {error, empty_file};
        {ok, Bin} ->
            try erlang:binary_to_term(Bin) of
                Block ->
                    case blockchain_block:is_block(Block) of
                        true ->
                            {ok, Block};
                        _ ->
                            {error, not_record}
                    end
            catch
                Error ->
                    {error, Error}
            end;
        Error ->
            Error
    end.
