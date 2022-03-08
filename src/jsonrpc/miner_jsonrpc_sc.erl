-module(miner_jsonrpc_sc).
-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%
handle_rpc(<<"sc_active">>, []) ->
    case (catch blockchain_state_channels_server:get_actives()) of
        {'EXIT', _} ->
            ?jsonrpc_error(timeout);
        ActiveScs ->
            #{<<"active">> => [ ?TO_VALUE(base64:encode(I)) || I <- maps:keys(ActiveScs) ]}
    end;
handle_rpc(<<"sc_active">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(<<"sc_list">>, []) ->
    case (catch blockchain_state_channels_server:get_all()) of
        {'EXIT', _} -> ?jsonrpc_error(timeout);
        SCs -> format_sc_map(SCs)
    end;
handle_rpc(<<"sc_list">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).

%%
%% Internal
%%
format_sc_map(SCs) ->
    {ok, Height} = blockchain:height(blockchain_worker:blockchain()),
    ActiveSCIDs = maps:keys(blockchain_state_channels_server:get_actives()),
    maps:fold(
        fun(SCID, SC, Acc) ->
            #{expire_at_block := ExpireAt} = Json = blockchain_state_channel_v1:to_json(SC, []),
            [
                Json#{
                    <<"is_active">> => lists:member(SCID, ActiveSCIDs),
                    <<"expired">> => Height >= ExpireAt
                }
                | Acc
            ]
        end,
        [],
        SCs
    ).
