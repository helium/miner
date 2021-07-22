-module(miner_jsonrpc_sc).
-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%
handle_rpc(<<"sc_active">>, []) ->
    case (catch blockchain_state_channels_server:active_sc_ids()) of
        {'EXIT', _} -> ?jsonrpc_error(timeout);
        undefined -> #{<<"active">> => []};
        BinIds -> #{<<"active">> => [ ?TO_VALUE(base64:encode(I)) || I <- BinIds ]}
    end;
handle_rpc(<<"sc_active">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"sc_list">>, []) ->
    case (catch blockchain_state_channels_server:state_channels()) of
        {'EXIT', _} -> ?jsonrpc_error(timeout);
        undefined -> #{<<"channels">> => []};
        SCs -> format_sc_list(SCs)
    end;
handle_rpc(<<"sc_list">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%%
%% Internal
%%
format_sc_list(SCs) ->
    {ok, Height} = blockchain:height(blockchain_worker:blockchain()),
    ActiveIds = blockchain_state_channels_server:active_sc_ids(),
    maps:fold(fun(_SCID, {SC, _Skew}, Acc) ->
                      #{ expire_at_block := ExpireAt } = Json
                      = blockchain_state_channel_v1:to_json(SC, []),
                      [ Json#{ <<"is_active">> => lists:member(SC, ActiveIds),
                               <<"expired">> => Height >= ExpireAt } | Acc ]
              end, [], SCs).
