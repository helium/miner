-define(jsonrpc_b58_to_bin(K, P), miner_jsonrpc_handler:jsonrpc_b58_to_bin((K), (P))).
-define(jsonrpc_b64_to_bin(K, P), miner_jsonrpc_handler:jsonrpc_b64_to_bin((K), (P))).
-define(jsonrpc_error(E), miner_jsonrpc_handler:jsonrpc_error((E))).

-define(BIN_TO_B58(B), list_to_binary(libp2p_crypto:bin_to_b58((B)))).
-define(B58_TO_BIN(B), libp2p_crypto:b58_to_bin(binary_to_list((B)))).

-define(BIN_TO_B64(B), base64url:encode((B))).
-define(B64_TO_BIN(B), base64url:decode((B))).

-define(TO_KEY(K), miner_jsonrpc_handler:to_key(K)).
-define(TO_VALUE(V), miner_jsonrpc_handler:to_value(V)).
-define(B58_TO_ANIMAL(V), iolist_to_binary(element(2, erl_angry_purple_tiger:animal_name(V)))).
-define(BIN_TO_ANIMAL(V),
    iolist_to_binary(
        element(2, erl_angry_purple_tiger:animal_name(?BIN_TO_B58(V)))
    )
).
-define(MAYBE(X), miner_jsonrpc_handler:jsonrpc_maybe(X)).
