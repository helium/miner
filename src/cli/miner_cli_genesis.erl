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
                   genesis_export_usage(),
                   genesis_key_usage(),
                   genesis_proof_usage()
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
                   genesis_export_cmd(),
                   genesis_key_cmd(),
                   genesis_proof_cmd()
                  ]).
%%
%% genesis
%%

genesis_usage() ->
    [["genesis"],
     ["miner genesis commands\n\n",
      "  genesis create <old_genesis_file> <addrs>  - Create genesis block keeping old ledger transactions.\n",
      "  genesis forge <pubkey> <key_proof> <addrs> - Create genesis block from scratch just with the addresses.\n",
      "  genesis load <genesis_file>                - Load genesis block from file.\n"
      "  genesis export <path>                      - Write genesis block to a file.\n"
      "  genesis key                                - create a keypair for use as a master key\n"
      "  genesis proof <privkey>                    - create a key proof for adding a master key to the genesis block\n"
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
    {ok, N} = application:get_env(blockchain, num_consensus_members),
    {ok, Curve} = application:get_env(miner, curve),
    create(OldGenesisFile, Addrs, N, Curve);
genesis_create(["genesis", "create", OldGenesisFile, Addrs, N], [], []) ->
    {ok, Curve} = application:get_env(miner, curve),
    create(OldGenesisFile, Addrs, list_to_integer(N), Curve);
genesis_create(["genesis", "create", OldGenesisFile, Addrs, N, Curve], [], []) ->
    create(OldGenesisFile, Addrs, list_to_integer(N), list_to_atom(Curve));
genesis_create(_, [], []) ->
    usage.

create(OldGenesisFile, Addrs, N, Curve) ->
    case file:consult(OldGenesisFile) of
        {ok, [Config]} ->
            OldSecurities = [blockchain_txn_security_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                                     proplists:get_value(token, X)) || X <- proplists:get_value(securities, Config)],
            OldAccounts = [blockchain_txn_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                          proplists:get_value(balance, X)) || X <- proplists:get_value(accounts, Config)],
            OldGateways = [blockchain_txn_gen_gateway_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(gateway_address, X)),
                                                             libp2p_crypto:b58_to_bin(proplists:get_value(owner_address, X)),
                                                             proplists:get_value(location, X),
                                                             proplists:get_value(nonce, X)) || X <- proplists:get_value(gateways, Config)],
            OldGenesisTransactions = OldAccounts ++ OldGateways ++ OldSecurities,
            Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
            InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
            miner_consensus_mgr:initial_dkg(OldGenesisTransactions ++ InitialPaymentTransactions, Addresses, N, Curve),
            [clique_status:text("ok")];
        {error, Reason} ->
            [clique_status:text(io_lib:format("~p", [Reason]))]
    end.

%%
%% genesis forge
%%

genesis_forge_cmd() ->
    [
     [["genesis", "forge", '*', '*', '*'], [], [], fun genesis_forge/3]
    ].

genesis_forge_usage() ->
    [["genesis", "forge"],
     ["genesis forge <addrs> \n\n",
      "  forge a new genesis block.\n\n"
     ]
    ].

genesis_forge(["genesis", "forge", PubKey, Proof, Addrs], [], []) ->
    {ok, N} = application:get_env(blockchain, num_consensus_members),
    {ok, Curve} = application:get_env(miner, curve),
    forge(PubKey, Proof, Addrs, N, Curve);
genesis_forge(["genesis", "forge", PubKey, Proof, Addrs, N], [], []) ->
    {ok, Curve} = application:get_env(miner, curve),
    forge(PubKey, Proof, Addrs, list_to_integer(N), Curve);
genesis_forge(["genesis", "forge", PubKey, Proof, Addrs, N, Curve], [], []) ->
    forge(PubKey, Proof, Addrs, list_to_integer(N), list_to_atom(Curve));
genesis_forge(_, [], []) ->
    usage.

forge(PubKeyB58, ProofB58, Addrs, N, Curve) ->
    BinPub = libp2p_crypto:b58_to_bin(PubKeyB58),
    Proof = base58:base58_to_binary(ProofB58),

    VarTxn = blockchain_txn_vars_v1:new(make_vars(), <<>>, #{master_key => BinPub,
                                                             key_proof => Proof}),

    Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    %% NOTE: This is mostly for locally testing run.sh so we have nodes added as gateways in the genesis block
    InitialGatewayTransactions = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, 16#8c283475d4e89ff, 0)
                                  || Addr <- Addresses ],
    miner_consensus_mgr:initial_dkg([VarTxn] ++
                                        InitialPaymentTransactions ++
                                        InitialGatewayTransactions,
                                    Addresses, N, Curve),
    [clique_status:text("ok")].

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


%%% genesis key and proof

genesis_key_cmd() ->
    [
     [["genesis", "key"], [], [], fun genesis_key/3]
    ].

genesis_key_usage() ->
    [["genesis", "key"],
     ["genesis key\n\n",
      "  create and print a new keypair\n\n"
     ]
    ].

genesis_proof_cmd() ->
    [
     [["genesis", "proof", '*'], [], [], fun genesis_proof/3]
    ].

genesis_proof_usage() ->
    [["genesis", "proof"],
     ["genesis proof <privkey>\n\n",
      "  using <privkey> construct a proof suitable for the genesis block\n\n"
     ]
    ].

genesis_key(["genesis", "key" | _], [], []) ->
    Keys =
        libp2p_crypto:generate_keys(ecc_compact),
    Bin = libp2p_crypto:keys_to_bin(Keys),
    B58 = base58:binary_to_base58(Bin),
    [clique_status:text([B58])];
genesis_key(_asd, [], []) ->
    usage.

genesis_proof(["genesis", "proof", PrivKeyB58], [], []) ->
    PrivKeyBin = base58:base58_to_binary(PrivKeyB58),
    #{secret := Priv, public := Pub} = libp2p_crypto:keys_from_bin(PrivKeyBin),
    Vars = make_vars(),
    KeyProof = blockchain_txn_vars_v1:create_proof(Priv, Vars),
    [clique_status:text(io_lib:format("Proof:~n~s~nPubKey:~n~s",
                                      [base58:binary_to_base58(KeyProof),
                                       libp2p_crypto:pubkey_to_b58(Pub)]))];
genesis_proof(_, [], []) ->
    usage.

make_vars() ->
    {ok, BlockTime} = application:get_env(miner, block_time),
    {ok, Interval} = application:get_env(miner, election_interval),
    {ok, BatchSize} = application:get_env(miner, batch_size),
    {ok, Curve} = application:get_env(miner, curve),
    {ok, N} = application:get_env(blockchain, num_consensus_members),

    #{block_time => BlockTime,
      election_interval => Interval,
      election_restart_interval => 10,
      num_consensus_members => N,
      batch_size => BatchSize,
      vars_commit_delay => 2,
      block_version => v1,
      dkg_curve => Curve,
      garbage_value => totes_garb,
      predicate_callback_mod => miner,
      predicate_callback_fun => test_version,
      proposal_threshold => 0.85}.
