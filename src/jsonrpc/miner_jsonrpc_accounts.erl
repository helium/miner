-module(miner_jsonrpc_accounts).

-include("miner_jsonrpc.hrl").
-behavior(miner_jsonrpc_handler).

%% jsonrpc_handler
-export([handle_rpc/2]).

%%
%% jsonrpc_handler
%%

handle_rpc(<<"account_get">>, #{ <<"address">> := AddressStr }) ->
    Address = ?B58_TO_BIN(AddressStr),
    Ledger = blockchain:ledger(blockchain_worker:blockchain()),
    GetBalance = fun() ->
                         case blockchain_ledger_v1:find_entry(Address, Ledger) of
                             {ok, Entry} ->
                                 #{ balance => blockchain_ledger_entry_v1:balance(Entry),
                                    nonce => blockchain_ledger_entry_v1:nonce(Entry)
                                  };
                                _ ->
                                 #{ balance => 0,
                                    nonce => 0
                                  }
                         end
                 end,
    GetSecurities = fun() ->
                            case blockchain_ledger_v1:find_security_entry(Address, Ledger) of
                                {ok, Entry} ->
                                    #{ sec_balance => blockchain_ledger_security_entry_v1:balance(Entry),
                                       sec_nonce => blockchain_ledger_security_entry_v1:nonce(Entry)
                                     };
                                _ ->
                                    #{ sec_balance => 0,
                                       sec_nonce => 0
                                     }
                            end
                    end,
    GetDCs = fun() ->
                     case blockchain_ledger_v1:find_dc_entry(Address, Ledger) of
                                {ok, Entry} ->
                                    #{ dc_balance => blockchain_ledger_data_credits_entry_v1:balance(Entry),
                                       dc_nonce => blockchain_ledger_data_credits_entry_v1:nonce(Entry)
                                     };
                                _ ->
                                    #{ dc_balance => 0,
                                       dc_nonce => 0
                                     }
                            end
                    end,
    lists:foldl(fun(Fun, Map) ->
                        maps:merge(Map, Fun())
                end,
                #{
                  address => ?BIN_TO_B58(Address)
                 },
                [GetBalance, GetSecurities, GetDCs]);
handle_rpc(<<"account_get">>, Params) ->
    ?jsonrpc_error({invalid_params, Params});
handle_rpc(_, _) ->
    ?jsonrpc_error(method_not_found).
