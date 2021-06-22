%%%-------------------------------------------------------------------
%% @doc miner_cli_genesis
%% @end
%%%-------------------------------------------------------------------
-module(miner_cli_genesis).

-behavior(clique_handler).

-export([register_cli/0]).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

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
      "  genesis create <old_genesis_file> <pubkey> <proof> <addrs>  - Create genesis block keeping old ledger transactions.\n",
      "  genesis forge <pubkey> <key_proof> <addrs>                  - Create genesis block from scratch just with the addresses.\n",
      "  genesis load <genesis_file>                                 - Load genesis block from file.\n"
      "  genesis export <path>                                       - Write genesis block to a file.\n"
      "  genesis key                                                 - create a keypair for use as a master key\n"
      "  genesis proof <privkey>                                     - create a key proof for adding a master key to the genesis block\n"
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
     [["genesis", "create", '*', '*', '*', '*'], [], [], fun genesis_create/3]
    ].

genesis_create_usage() ->
    [["genesis", "create"],
     ["genesis create <old_genesis_file> <pubkey> <proof> <addrs> \n\n",
      "  create a new genesis block.\n\n"
     ]
    ].

genesis_create(["genesis", "create", OldGenesisFile, Pubkey, Proof, Addrs], [], []) ->
    {ok, N} = application:get_env(blockchain, num_consensus_members),
    {ok, Curve} = application:get_env(miner, curve),
    create(OldGenesisFile, Pubkey, Proof, Addrs, N, Curve);
genesis_create(["genesis", "create", OldGenesisFile, Pubkey, Proof, Addrs, N], [], []) ->
    {ok, Curve} = application:get_env(miner, curve),
    create(OldGenesisFile, Pubkey, Proof, Addrs, list_to_integer(N), Curve);
genesis_create(["genesis", "create", OldGenesisFile, Pubkey, Proof, Addrs, N, Curve], [], []) ->
    create(OldGenesisFile, Pubkey, Proof, Addrs, list_to_integer(N), list_to_atom(Curve));
genesis_create(_, [], []) ->
    usage.

create(OldGenesisFile, PubKeyB58, ProofB58, Addrs, N, Curve) ->
    case file:consult(OldGenesisFile) of
        {ok, [Config]} ->
            BinPub = libp2p_crypto:b58_to_bin(PubKeyB58),
            Proof = base58:base58_to_binary(ProofB58),

            VarTxn = blockchain_txn_vars_v1:new(make_vars(), 1, #{master_key => BinPub}),
            VarTxn1 = blockchain_txn_vars_v1:key_proof(VarTxn, Proof),

            OldSecurities = case proplists:get_value(securities, Config) of
                                undefined -> [];
                                Securities ->
                                    [blockchain_txn_security_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                                             proplists:get_value(token, X)) || X <- Securities]
                            end,

            OldAccounts = case proplists:get_value(accounts, Config) of
                              undefined -> [];
                              Accounts ->
                                  [blockchain_txn_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                                  proplists:get_value(balance, X)) || X <- Accounts]
                          end,

            OldGateways = case proplists:get_value(gateways, Config) of
                              undefined -> [];
                              Gateways ->
                                  [blockchain_txn_gen_gateway_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(gateway_address, X)),
                                                                     libp2p_crypto:b58_to_bin(proplists:get_value(owner_address, X)),
                                                                     proplists:get_value(location, X),
                                                                     proplists:get_value(nonce, X)) || X <- Gateways]
                          end,

            OldDCs = case proplists:get_value(dcs, Config) of
                         undefined -> [];
                         DCs ->
                             [ blockchain_txn_dc_coinbase_v1:new(libp2p_crypto:b58_to_bin(proplists:get_value(address, X)),
                                                                 proplists:get_value(dc_balance, X)) || X <- DCs]
                     end,

            OldGenesisTransactions = OldAccounts ++ OldGateways ++ OldSecurities ++ OldDCs,
            Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
            miner_consensus_mgr:initial_dkg(OldGenesisTransactions ++ [VarTxn1], Addresses, N, Curve),
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

    VarTxn = blockchain_txn_vars_v1:new(make_vars(), 1, #{master_key => BinPub}),
    VarTxn1 = blockchain_txn_vars_v1:key_proof(VarTxn, Proof),

    Addresses = [libp2p_crypto:p2p_to_pubkey_bin(Addr) || Addr <- string:split(Addrs, ",", all)],
    InitialPaymentTransactions = [ blockchain_txn_coinbase_v1:new(Addr, 500000000) || Addr <- Addresses],
    %% Give security tokens to 2 members
    InitialSecurityTransactions = [ blockchain_txn_security_coinbase_v1:new(Addr, 5000000)
                                    || Addr <- lists:sublist(Addresses, 2)],
    %% Give DCs to 2 members
    InitialDCs = [ blockchain_txn_dc_coinbase_v1:new(Addr, 10000000) || Addr <- lists:sublist(Addresses, 2)],
    %% NOTE: This is mostly for locally testing run.sh so we have nodes added as gateways in the genesis block

    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/10}, 12)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),


    LocAddresses = lists:zip(Locations, Addresses),
    %% InitialGatewayTransactions = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0)
    %%                               || {Loc, Addr} <- LocAddresses ],
    InitialGatewayTransactions = [blockchain_txn_gen_validator_v1:new(Addr, Addr, 10000 * 100000000)
                                  || {_Loc, Addr} <- LocAddresses ],
    miner_consensus_mgr:initial_dkg([VarTxn1] ++
                                        InitialPaymentTransactions ++
                                        InitialGatewayTransactions ++
                                        InitialSecurityTransactions ++
                                        InitialDCs,
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

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),
    Txn = blockchain_txn_vars_v1:new(Vars, 1, #{master_key => BinPub}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),

    [clique_status:text(io_lib:format("Proof:~n~s~nPubKey:~n~s",
                                      [base58:binary_to_base58(Proof),
                                       libp2p_crypto:pubkey_to_b58(Pub)]))];
genesis_proof(_, [], []) ->
    usage.

make_vars() ->
    {ok, BlockTime} = application:get_env(miner, block_time),
    {ok, Interval} = application:get_env(miner, election_interval),
    {ok, BatchSize} = application:get_env(miner, batch_size),
    {ok, Curve} = application:get_env(miner, curve),
    {ok, N} = application:get_env(blockchain, num_consensus_members),

    #{?chain_vars_version => 2,
      ?block_time => BlockTime,
      ?election_interval => Interval,
      ?election_restart_interval => 5,
      ?election_version => 5,
      ?election_bba_penalty => 0.01,
      ?election_seen_penalty => 0.25,
      ?election_selection_pct => 75,
      ?election_replacement_factor => 4,
      ?election_replacement_slope => 20,
      ?election_removal_pct => 85,
      ?election_cluster_res => 8,
      ?num_consensus_members => N,
      ?batch_size => BatchSize,
      ?vars_commit_delay => 1,
      ?var_gw_inactivity_threshold => 600,
      ?block_version => v1,
      ?dkg_curve => Curve,
      ?predicate_callback_mod => miner,
      ?predicate_callback_fun => version,
      ?predicate_threshold => 0.95,
      ?monthly_reward => ?bones(1000000),
      ?securities_percent => 0.35,
      ?dc_percent => 0.0,
      ?poc_centrality_wt => 0.5,
      ?poc_challenge_sync_interval=> 30,
      ?poc_challengees_percent=> 0.35,
      ?poc_challengers_percent=> 0.15,
      ?poc_good_bucket_high=> -80,
      ?poc_good_bucket_low=> -115,
      ?poc_max_hop_cells=> 2000,
      ?poc_path_limit=> 7,
      ?poc_target_hex_parent_res=> 5,
      ?poc_typo_fixes=> true,
      ?poc_v4_exclusion_cells=> 8,
      ?poc_v4_parent_res=> 11,
      ?poc_v4_prob_bad_rssi=> 0.01,
      ?poc_v4_prob_count_wt=> 0.0,
      ?poc_v4_prob_good_rssi=> 1.0,
      ?poc_v4_prob_no_rssi=> 0.5,
      ?poc_v4_prob_rssi_wt=> 0.0,
      ?poc_v4_prob_time_wt=> 0.0,
      ?poc_v4_randomness_wt=> 0.5,
      ?poc_v4_target_challenge_age=> 300,
      ?poc_v4_target_exclusion_cells=> 6000,
      ?poc_v4_target_prob_edge_wt=> 0.0,
      ?poc_v4_target_prob_score_wt=> 0.0,
      ?poc_v4_target_score_curve=> 5,
      ?poc_v5_target_prob_randomness_wt=> 1.0,
      ?poc_version=> 8,
      ?poc_witnesses_percent=> 0.05,
      ?consensus_percent => 0.10,
      ?min_score => 0.15,
      ?alpha_decay => 0.007,
      ?beta_decay => 0.0005,
      ?max_staleness => 100000,
      ?poc_challenge_interval => 20,
      ?min_assert_h3_res => 12,
      ?h3_neighbor_res => 12,
      ?h3_max_grid_distance => 120,
      ?h3_exclusion_ring_dist => 6,
      ?snapshot_version => 1,
      ?sc_grace_blocks => 20,
      ?snapshot_interval => 5,
      ?rewards_txn_version => 2,
      ?validator_version => 2,
      ?validator_minimum_stake => 10000 * 100000000,
      ?validator_liveness_grace_period => 10,
      ?validator_liveness_interval => 20,
      ?validator_penalty_filter => 10.0,
      ?dkg_penalty => 1.0,
      ?tenure_penalty => 1.0,
      ?penalty_history_limit => 100
     }.
