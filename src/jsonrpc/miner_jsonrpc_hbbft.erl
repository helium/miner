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

handle_rpc(<<"hbbft_status">>, []) ->
    miner:hbbft_status();
handle_rpc(<<"hbbft_skip">>, []) ->
    Result = miner:hbbft_skip(),
    #{result => Result};
handle_rpc(<<"hbbft_queue">>, []) ->
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
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).
