-module(miner_jsonrpc_hbbft).

-include("miner_jsonrpc.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(Method, []) ->
    handle_rpc_(Method, []);
handle_rpc(Method, {Params}) ->
    handle_rpc(Method, kvc:to_proplist({Params}));
handle_rpc(Method, Params) when is_list(Params) ->
    handle_rpc(Method, maps:from_list(Params));
handle_rpc(Method, Params) when is_map(Params) andalso map_size(Params) == 0 ->
    handle_rpc_(Method, []);
handle_rpc(Method, Params) when is_map(Params) ->
    handle_rpc_(Method, Params).

handle_rpc_(<<"hbbft_status">>, []) ->
    miner:hbbft_status();
handle_rpc_(<<"hbbft_skip">>, []) ->
    Result = miner:hbbft_skip(),
    #{result => Result};
handle_rpc_(<<"hbbft_queue">>, []) ->
    #{
        inbound := Inbound,
        outbound := Outbound
    } = miner:relcast_queue(consensus_group),
    Workers = miner:relcast_info(consensus_group),
    Outbound1 = maps:map(
        fun(K, V) ->
            #{
                address := Raw,
                connected := Connected,
                ready := Ready,
                in_flight := InFlight,
                connects := Connects,
                last_take := LastTake,
                last_ack := LastAck
            } = maps:get(K, Workers),
            #{
                address => ?TO_B58(Raw),
                name => ?TO_ANIMAL_NAME(Raw),
                count => length(V),
                connected => Connected,
                blocked => not Ready,
                in_flight => InFlight,
                connects => Connects,
                last_take => LastTake,
                last_ack => erlang:system_time(seconds) - LastAck
            }
        end,
        Outbound
    ),
    #{
        inbound => length(Inbound),
        outbound => Outbound1
    };
handle_rpc_(_, _) ->
    ?jsonrpc_error(method_not_found).
