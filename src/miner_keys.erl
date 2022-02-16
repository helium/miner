-module(miner_keys).

-include_lib("public_key/include/public_key.hrl").

-export([key_config/0,
         key_proplist_to_uri/1,
         key_uri_to_proplist/1,
         keys/0,
         keys/1,
         libp2p_to_gateway_key/1,
         print_keys/1]).

-type key_configuration() :: {ecc, proplists:proplist()} | {file, BaseDir :: string()}.

-type key_info() :: #{
    pubkey => libp2p_crypto:pubkey(),
    key_slot => non_neg_integer() | undefined,
    ecdh_fun => libp2p_crypto:ecdh_fun(),
    sig_fun => libp2p_crypto:sig_fun(),
    onboarding_key => string() | undefined,
    bus => string(),
    address => non_neg_integer()
}.

-export_type([key_info/0, key_configuration/0]).

-spec get_onboarding_filename() -> string() | undefined.
get_onboarding_filename() ->
    case application:get_env(blockchain, onboarding_dir) of
        undefined -> undefined;
        {ok, OnboardingDir} -> filename:join([OnboardingDir, "onboarding_key"])
    end.

-spec get_onboarding_key(string()) -> string() | undefined.
get_onboarding_key(Default) ->
    case get_onboarding_filename() of
        undefined ->
            Default;
        OnboardingKey ->
            case file:read_file(OnboardingKey) of
                {ok, Bin} -> string:trim(binary_to_list(Bin));
                {error, enoent} -> Default;
                {error, _Reason} -> undefined
            end
    end.

%% @doc Fetch the miner key, onboarding key, keyslot and associated
%% signing and ecdh functions from either a file (for non-hardware
%% based hotspots)or the ECC.
%%
%% NOTE: Do NOT call this after miner has started since this function
%% will attempt to communicate directly with the ECC. Use only as part
%% of startup or other miner-free scripts.
-spec keys() -> key_info().
keys() ->
    keys(key_config()).

-spec keys(key_configuration()) -> key_info().
keys({file, BaseDir}) ->
    case application:get_env(miner, gateway_and_mux_enable) of
        {ok, true} ->
            {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
            #{
                pubkey => PubKey,
                key_slot => undefined,
                bus => undefined,
                address => undefined,
                %% The signing and ecdh functions will use an actual
                %% worker against a named process.
                ecdh_fun => fun(PublicKey) ->
                    {ok, Bin} = miner_gateway_ecc_worker:ecdh(PublicKey),
                    Bin
                end,
                sig_fun => fun(Bin) ->
                    {ok, Sig} = miner_gateway_ecc_worker:sign(Bin),
                    Sig
                end,
                onboarding_key => libp2p_crypto:pubkey_to_b58(PubKey)
            };
        _ ->
            SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
            ok = filelib:ensure_dir(SwarmKey),
            case libp2p_crypto:load_keys(SwarmKey) of
                {ok, #{secret := PrivKey0, public := PubKey}} ->
                    FallbackOnboardingKey = libp2p_crypto:pubkey_to_b58(PubKey),
                    #{
                        pubkey => PubKey,
                        key_slot => undefined,
                        bus => undefined,
                        address => undefined,
                        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
                        sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
                        onboarding_key => get_onboarding_key(FallbackOnboardingKey)
                    };
                {error, enoent} ->
                    Network = application:get_env(miner, network, mainnet),
                    KeyMap =
                        #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(
                            Network,
                            ecc_compact
                        ),
                    ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
                    FallbackOnboardingKey = libp2p_crypto:pubkey_to_b58(PubKey),
                    #{
                        pubkey => PubKey,
                        key_slot => undefined,
                        bus => undefined,
                        address => undefined,
                        ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
                        sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
                        onboarding_key => get_onboarding_key(FallbackOnboardingKey)
                    }
            end
    end;
keys({ecc, Options}) when is_list(Options) ->
    case application:get_env(miner, gateway_and_mux_enable) of
        {ok, true} ->
            KeyOptionsMap =
                case io_lib:char_list(Options) of
                    true ->
                        KeyList = key_uri_to_proplist(Options),
                        key_proplist_to_map(KeyList);
                    _ ->
                        key_proplist_to_map(Options)
                end,
            {ok, PubKey} = miner_gateway_ecc_worker:pubkey(),
            maps:merge(
                #{ pubkey => PubKey,
                   onboarding_key => libp2p_crypto:pubkey_to_b58(PubKey),
                   %% The signing and ecdh functions will use an actual
                   %% worker against a named process.
                   ecdh_fun => fun(PublicKey) ->
                       {ok, Bin} = miner_gateway_ecc_worker:ecdh(PublicKey),
                       Bin
                   end,
                   sig_fun => fun(Bin) ->
                       {ok, Sig} = miner_gateway_ecc_worker:sign(Bin),
                       Sig
                   end
                }, KeyOptionsMap);
        _ ->
            KeySlot0 = proplists:get_value(key_slot, Options, 0),
            OnboardingKeySlot = proplists:get_value(onboarding_key_slot, Options, 15),
            Bus = proplists:get_value(bus, Options, "i2c-1"),
            Address = proplists:get_value(address, Options, 16#60),
            {ok, ECCPid} =
                case whereis(miner_ecc_worker) of
                    undefined ->
                        %% Create a temporary ecc link to get the public key and
                        %% onboarding keys for the given slots as well as the
                        ecc508:start_link(Bus, Address);
                    _ECCWorker ->
                        %% use the existing ECC pid
                        miner_ecc_worker:get_pid()
                end,
            {ok, PubKey, KeySlot} = get_public_key(ECCPid, KeySlot0),
            {ok, OnboardingKey} =
                case get_public_key(ECCPid, OnboardingKeySlot) of
                    {ok, Key, OnboardingKeySlot} ->
                        {ok, Key};
                    {error, empty_slot} ->
                        %% Key not present, this slot is (assumed to be) empty so use the public key
                        %% as the onboarding key
                        {ok, PubKey};
                    Other ->
                        Other
                end,
            case whereis(miner_ecc_worker) of
                undefined ->
                    %% Stop ephemeral ecc pid
                    ecc508:stop(ECCPid);
                _ ->
                    ok
            end,

            #{
                pubkey => PubKey,
                key_slot => KeySlot,
                bus => Bus,
                address => Address,
                %% The signing and ecdh functions will use an actual
                %% worker against a named process.
                ecdh_fun => fun(PublicKey) ->
                    {ok, Bin} = miner_ecc_worker:ecdh(PublicKey),
                    Bin
                end,
                sig_fun => fun(Bin) ->
                    {ok, Sig} = miner_ecc_worker:sign(Bin),
                    Sig
                end,
                onboarding_key => libp2p_crypto:pubkey_to_b58(OnboardingKey)
            }
    end.

-spec key_config() -> key_configuration().
key_config() ->
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    case application:get_env(blockchain, key, undefined) of
        undefined -> {file, BaseDir};
        KC -> KC
    end.

-spec libp2p_to_gateway_key(libp2p_crypto:key_map()) -> libp2p_crypto:key_map().
libp2p_to_gateway_key(#{secret := {ecc_compact, PrivKey}, network := Network}) ->
    {ok, #{
        secret => {ecc_compact, PrivKey#'ECPrivateKey'{publicKey = <<>>}},
        public => {ecc_compact, <<>>},
        network => Network
    }}.

%% @doc prints the public hotspot and onboadring key in a file:consult
%% friendly way to stdout. This is used by other services (like
%% gateway_config) to get read access to the public keys
print_keys(_) ->
    #{
        pubkey := PubKey,
        onboarding_key := OnboardingKey
    } = keys(),
    MaybeB58 = fun
        (undefined) -> undefined;
        (Key) -> libp2p_crypto:pubkey_to_b58(Key)
    end,
    Props =
        [
            {pubkey, MaybeB58(PubKey)},
            {onboarding_key, OnboardingKey}
        ] ++
            [
                {animal_name,
                    element(
                        2, erl_angry_purple_tiger:animal_name(libp2p_crypto:pubkey_to_b58(PubKey))
                    )}
             || PubKey /= undefined
            ],
    lists:foreach(fun(Term) -> io:format("~tp.~n", [Term]) end, Props),
    rpc_ok.

key_proplist_to_uri(Props) ->
    Bus = proplists:get_value(bus, Props, "i2c-1"),
    Address = proplists:get_value(address, Props, 16#60),
    KeySlot = proplists:get_value(key_slot, Props, 0),
    Network = application:get_env(miner, network, mainnet),
    lists:flatten(io_lib:format("ecc://~s:~p?slot=~p&network=~s", [Bus, Address, KeySlot, Network])).

key_uri_to_proplist(Uri) ->
    #{host := Bus, port := Address, query := Query} = uri_string:parse(Uri),
    QueryList = lists:foldl(fun({"slot", Slot}, Acc) ->
                                   [{key_slot, list_to_integer(Slot)} | Acc];
                               ({"network", Network}, Acc) ->
                                   [{network, Network} | Acc];
                               (_, Acc) -> Acc
                            end, [], uri_string:dissect_query(Query)),
    [{bus, Bus}, {address, Address}] ++ QueryList.
%%
%% Utilities
%%

key_proplist_to_map(Options) when is_list(Options) ->
    #{
        key_slot => proplists:get_value(key_slot, Options, 0),
        bus => proplists:get_value(bus, Options, "i2c-1"),
        address => proplists:get_value(address, Options, 16#60)
    }.

%% Helper funtion to retry automatic keyslot key generation and
%% locking the first time we encounter an empty keyslot.
get_public_key(ECCPid, Slot) ->
    get_public_key(ECCPid, Slot, 20).

get_public_key(_ECCPid, _Slot, 0) ->
    {error, too_many_retries};
get_public_key(ECCPid, Slot, Retries) ->
    ecc508:wake(ECCPid),
    case ecc508:genkey(ECCPid, public, Slot) of
        {ok, PubKey} ->
            case ecc_compact:is_compact(PubKey) of
                {true, _} ->
                    {ok, {ecc_compact, PubKey}, Slot};
                false ->
                    %% initial hotspots had a bug where they
                    %% did not generate a compact key here.
                    %% This code is fallback to use a secondary
                    %% slot to handle this case.
                    get_public_key(ECCPid, Slot + 1)
            end;
        {error, ecc_response_exec_error} ->
            %% key is not present
            {error, empty_slot};
        {error, _} ->
            %% sometimes we get a different error here, so wait a bit
            %% and try again, failing after 2 seconds
            timer:sleep(150),
            get_public_key(ECCPid, Slot, Retries - 1)
    end.
