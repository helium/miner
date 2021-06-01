-module(miner_jsonrpc_blocks).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

-export([handle_rpc/2]).

handle_rpc(<<"block_height">>, []) ->
    {ok, Height} = blockchain:height(blockchain_worker:blockchain()),
    #{ height => Height };
handle_rpc(<<"block_height">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});

handle_rpc(<<"block_get">>, #{ <<"height">> := Height }) when is_integer(Height) ->
    lookup_block(Height);
handle_rpc(<<"block_get">>, #{ <<"hash">> := Hash }) when is_binary(Hash) ->
    try
        BinHash = ?B64_TO_BIN(Hash),
        lookup_block(BinHash)
    catch
        _:_ -> ?jsonrpc_error({invalid_params, Hash})
    end;
handle_rpc(<<"block_get">>, []) ->
    {ok, Height} = blockchain:height(blockchain_worker:blockchain()),
    lookup_block(Height);
handle_rpc(<<"block_get">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

lookup_block(BlockId) ->
    case blockchain:get_block(BlockId, blockchain_worker:blockchain()) of
        {ok, Block} ->
            blockchain_block:to_json(Block, []);
        {error, not_found} ->
            ?jsonrpc_error({not_found, "Block not found: ~p", [BlockId]});
        {error, _}=Error ->
            ?jsonrpc_error(Error)
    end.

