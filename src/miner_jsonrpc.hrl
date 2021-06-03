-define (jsonrpc_get_param(K,P), miner_jsonrpc_handler:jsonrpc_get_param((K),(P))).
-define (jsonrpc_get_param(K,P,D), miner_jsonrpc_handler:jsonrpc_get_param((K),(P),(D))).
-define (jsonrpc_b58_to_bin(K,P), miner_jsonrpc_handler:jsonrpc_b58_to_bin((K),(P))).
-define (jsonrpc_b64_to_bin(K,P), miner_jsonrpc_handler:jsonrpc_b64_to_bin((K),(P))).
-define(jsonrpc_error(E), miner_jsonrpc_handler:jsonrpc_error((E))).

-define (BIN_TO_B58(B), list_to_binary(libp2p_crypto:bin_to_b58((B)))).
-define (B58_TO_BIN(B), libp2p_crypto:b58_to_bin(binary_to_list((B)))).

-define (BIN_TO_B64(B), base64url:encode((B))).
-define (B64_TO_BIN(B), base64url:decode((B))).
