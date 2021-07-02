-module(miner_keys).

-export([key_config/0, keys/0, keys/1, print_keys/1]).

-type key_configuration() :: {ecc, proplists:proplist()} | {file, BaseDir::string()}.

-type key_info() :: #{ pubkey => libp2p_crypto:pubkey(),
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
        {ok, OnboardingDir} ->
            filename:join([OnboardingDir, "onboarding_key"])
    end.

-spec get_onboarding_key(string()) -> string() | undefined.
get_onboarding_key(Default) ->
    case get_onboarding_filename() of
        undefined -> Default;
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
    SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    case libp2p_crypto:load_keys(SwarmKey) of
        {ok, #{secret := PrivKey0, public := PubKey}} ->
            FallbackOnboardingKey = libp2p_crypto:pubkey_to_b58(PubKey),
            #{ pubkey => PubKey,
               key_slot => undefined,
               ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
               sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
               onboarding_key => get_onboarding_key(FallbackOnboardingKey)
             };
        {error, enoent} ->
            KeyMap = #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
            FallbackOnboardingKey = libp2p_crypto:pubkey_to_b58(PubKey),
            #{ pubkey => PubKey,
               key_slot => undefined,
               ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
               sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
               onboarding_key => get_onboarding_key(FallbackOnboardingKey)
             }
    end;
keys({ecc, Props}) when is_list(Props) ->
    KeySlot0 = proplists:get_value(key_slot, Props, 0),
    OnboardingKeySlot = proplists:get_value(onboarding_key_slot, Props, 15),
    Bus = proplists:get_value(bus, Props, "i2c-1"),
    Address = proplists:get_value(address, Props, 16#60),
    {ok, ECCPid} = case whereis(miner_ecc_worker) of
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
            Other -> Other
        end,
    case whereis(miner_ecc_worker) of
        undefined ->
            %% Stop ephemeral ecc pid
            ecc508:stop(ECCPid);
        _ ->
            ok
    end,

    #{ pubkey => PubKey,
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
     }.

-spec key_config() -> key_configuration().
key_config() ->
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    case application:get_env(blockchain, key, undefined) of
        undefined -> {file, BaseDir};
        KC -> KC
    end.

%% @doc prints the public hotspot and onboadring key in a file:consult
%% friendly way to stdout. This is used by other services (like
%% gateway_config) to get read access to the public keys
print_keys(_) ->
    #{
       pubkey := PubKey,
       onboarding_key := OnboardingKey
     } = keys(),
    MaybeB58 = fun(undefined) -> undefined;
                  (Key) -> libp2p_crypto:pubkey_to_b58(Key)
               end,
    Props = [{pubkey, MaybeB58(PubKey)},
             {onboarding_key, OnboardingKey}
            ] ++ [ {animal_name, element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:pubkey_to_b58(PubKey)))} || PubKey /= undefined ],
    lists:foreach(fun(Term) -> io:format("~tp.~n", [Term]) end, Props),
    rpc_ok.

%%
%% Utilities
%%

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
