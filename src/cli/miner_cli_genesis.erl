%%%-------------------------------------------------------------------
%% @doc miner_cli_genesis
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_genesis).

-behavior(clique_handler).

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_cmds().

register_all_usage() ->
    lists:foreach(fun(Args) ->
                          apply(clique, register_usage, Args)
                  end,
                  [
                   genesis_usage(),
                   genesis_create_usage(),
                   genesis_forge_usage(),
                   genesis_load_usage(),
                   genesis_export_usage()
                  ]).

register_all_cmds() ->
    lists:foreach(fun(Cmds) ->
                          [apply(clique, register_command, Cmd) || Cmd <- Cmds]
                  end,
                  [
                   genesis_cmd(),
                   genesis_create_cmd(),
                   genesis_forge_cmd(),
                   genesis_load_cmd(),
                   genesis_export_cmd()
                  ]).
%%
%% genesis
%%

genesis_usage() ->
    [["genesis"],
     ["miner genesis commands\n\n",
      "  genesis create <old_genesis_file> <addrs> - Create genesis block keeping old ledger transactions.\n",
      "  genesis forge <addrs>                     - Create genesis block from scratch just with the addresses.\n",
      "  genesis load <genesis_file>               - Load genesis block from file.\n"
      "  genesis export <path>                     - Write genesis block to a file.\n"
     ]
    ].

genesis_cmd() ->
    [
     [["genesis"], [], [], fun(_, _, _) -> usage end]
    ].


%%
%% genesis create
%%

genesis_create_cmd() ->
    [
     [["genesis", "create", '*', '*'], [], [], fun genesis_create/3]
    ].

genesis_create_usage() ->
    [["genesis", "create"],
     ["genesis create <old_genesis_file> <addrs> \n\n",
      "  create a new genesis block.\n\n"
     ]
    ].

genesis_create(["genesis", "create", OldGenesisFile, Addrs], [], []) ->
    case file:consult(OldGenesisFile) of
        {ok, [Config]} ->
            OldAccounts = [blockchain_txn_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                       proplists:get_value(balance, X)) || X <- proplists:get_value(accounts, Config)],
            OldGateways = [blockchain_txn_gen_gateway_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(gateway_address, X)),
                                                          libp2p_crypto:b58_to_bin(proplists:get_value(owner_address, X)),
                                                          proplists:get_value(location, X),
                                                          proplists:get_value(last_poc_challenge, X),
                                                          proplists:get_value(nonce, X),
                                                          proplists:get_value(score, X)) || X <- proplists:get_value(gateways, Config)],
            OldGenesisTransactions = OldAccounts ++ OldGateways,
            Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
            InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
            miner:initial_dkg(OldGenesisTransactions ++ InitialPaymentTransactions, Addresses),
            [clique_status:text("ok")];
        {error, Reason} ->
            [clique_status:text(io_lib:format("~p", [Reason]))]
    end;
genesis_create([_, _, _], [], []) ->
    usage.

%%
%% genesis forge
%%

genesis_forge_cmd() ->
    [
     [["genesis", "forge", '*'], [], [], fun genesis_forge/3]
    ].

genesis_forge_usage() ->
    [["genesis", "forge"],
     ["genesis forge <addrs> \n\n",
      "  forge a new genesis block.\n\n"
     ]
    ].

genesis_forge(["genesis", "forge", Addrs], [], []) ->
    Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    %% NOTE: This is mostly for locally testing run.sh so we have nodes added as gateways in the genesis block
    AddGwTxns = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, undefined, undefined, 0, 0) || Addr <- Addresses],
    miner:initial_dkg(InitialPaymentTransactions ++ AddGwTxns, Addresses),
    [clique_status:text("ok")];
genesis_forge([_, _, _], [], []) ->
    usage.

%%
%% genesis load
%%

genesis_load_cmd() ->
    [
     [["genesis", "load", '*'], [], [], fun genesis_load/3]
    ].

genesis_load_usage() ->
    [["genesis", "load"],
     ["genesis load <genesis_file> \n\n",
      "  load a genesis block from file.\n\n"
     ]
    ].

genesis_load(["genesis", "load", GenesisFile], [], []) ->
    case file:read_file(GenesisFile) of
        {ok, GenesisBlock} ->
            io:format("Integrating genesis block from file..."),
            blockchain_worker:integrate_genesis_block(blockchain_block:deserialize(GenesisBlock));
        {error, Reason} ->
            io:format("Error, Reason: ~p", [Reason])
    end,
    [clique_status:text("ok")];
genesis_load([_, _, _], [], []) ->
    usage.

%%
%% genesis export
%%

genesis_export_cmd() ->
    [
     [["genesis", "export", '*'], [], [], fun genesis_export/3]
    ].

genesis_export_usage() ->
    [["genesis", "export"],
     ["genesis export <path_to_genesis_file> \n\n",
      "  export genesis block to a specified file.\n\n"
     ]
    ].

genesis_export(["genesis", "export", Filename], [], []) ->
    case blockchain_worker:blockchain() of
        undefined ->
            [clique_status:alert([clique_status:text("Undefined Blockchain")])];
        Chain ->
            case blockchain:genesis_block(Chain) of
                {error, Reason} ->
                    [clique_status:alert([clique_status:text(io_lib:format("~p", [Reason]))])];
                {ok, GenesisBlock} ->
                    case (catch file:write_file(Filename, blockchain_block:serialize(GenesisBlock))) of
                        {'EXIT', _} ->
                            usage;
                        ok ->
                            [clique_status:text(io_lib:format("ok, genesis file written to ~p", [Filename]))];
                        {error, Reason} ->
                            [clique_status:alert([clique_status:text(io_lib:format("~p", [Reason]))])]
                    end
            end
    end;
genesis_export([_, _, _], [], []) ->
    usage.
