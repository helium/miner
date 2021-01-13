-module(miner_keys).

-export([keys/1, print_keys/1]).

-type key_info() :: #{ pubkey => libp2p_crypto:pubkey(),
                       key_slot => non_neg_integer() | undefined,
                       ecdh_fun => libp2p_crypto:ecdh_fun(),
                       sig_fun => libp2p_crypto:sig_fun(),
                       onboarding_key => libp2p_crypto:pubkey() | undefined
                     }.
-export_type([key_info/0]).

get_onboarding_filename() ->
    case application:get_env(blockchain, onboarding_dir) of
        undefined -> undefined;
        {ok, OnboardingDir} ->
            filename:join([OnboardingDir, "onboarding_key"])
    end.

get_onboarding_key(Default) ->
    case get_onboarding_filename() of
        undefined -> Default;
        OnboardingKey ->
            case file:read_file(OnboardingKey) of
                {ok, Bin} -> Bin;
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
-spec keys({file, BaseDir::string()} |
           {ecc, proplists:proplist()}) -> key_info().
keys({file, BaseDir}) ->
    SwarmKey = filename:join([BaseDir, "miner", "swarm_key"]),
    ok = filelib:ensure_dir(SwarmKey),
    case libp2p_crypto:load_keys(SwarmKey) of
        {ok, #{secret := PrivKey0, public := PubKey}} ->
            #{ pubkey => PubKey,
               key_slot => undefined,
               ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
               sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
               onboarding_key => get_onboarding_key(PubKey)
             };
        {error, enoent} ->
            KeyMap = #{secret := PrivKey0, public := PubKey} = libp2p_crypto:generate_keys(ecc_compact),
            ok = libp2p_crypto:save_keys(KeyMap, SwarmKey),
            #{ pubkey => PubKey,
               key_slot => undefined,
               ecdh_fun => libp2p_crypto:mk_ecdh_fun(PrivKey0),
               sig_fun => libp2p_crypto:mk_sig_fun(PrivKey0),
               onboarding_key => get_onboarding_key(PubKey)
             }
    end;
keys({ecc, Props}) when is_list(Props) ->
    KeySlot0 = proplists:get_value(key_slot, Props, 0),
    OnboardingKeySlot = proplists:get_value(onboarding_key_slot, Props, 15),
    {ok, ECCPid} = case whereis(miner_ecc_worker) of
                       undefined ->
                           %% Create a temporary ecc link to get the public key and
                           %% onboarding keys for the given slots as well as the
                           ecc508:start_link();
                       _ECCWorker ->
                           %% use the existing ECC pid
                           miner_ecc_worker:get_pid()
                   end,
    {ok, PubKey, KeySlot} = get_public_key(ECCPid, KeySlot0),
    OnboardingKey = 
        case ecc508:genkey(ECCPid, public, OnboardingKeySlot) of
            {ok, Key} -> 
                {ecc_copmact, Key};
            {error, ecc_response_exec_error} -> 
                %% Key not present, this slot is (assumed to be) empty so use the public key 
                %% as the onboarding key
                PubKey
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
       onboarding_key => OnboardingKey
     }.


%% @doc prints the public hotspot and onboadring key in a file:consult
%% friendly way to stdout. This is used by other services (like
%% gateway_config) to get read access to the public keys
print_keys(_) ->
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    KeyConfig = case application:get_env(blockchain, key, undefined) of
                    undefined -> {file, BaseDir};
                    KC -> KC
                end,
    #{
       pubkey := PubKey,
       onboarding_key := OnboardingKey
     } = keys(KeyConfig),
    MaybeB58 = fun(undefined) -> undefined;
                  (Key) -> libp2p_crypto:pubkey_to_b58(Key)
               end,
    MaybeUUIDv4 = fun(undefined) -> undefined;
                  (Key) ->
                      %% only production blackspots read onboarding_key from a file 
                      %% and they're (unfortunately) considered to be uuids
                      OnboardingFilename = get_onboarding_filename(),
                      case filelib:is_file(OnboardingFilename) of
                          true ->
                              string:trim(binary_to_list(Key));
                          false ->
                              libp2p_crypto:pubkey_to_b58(Key)
                      end
               end,
    Props = [{pubkey, MaybeB58(PubKey)},
             {onboarding_key, MaybeUUIDv4(OnboardingKey)}
            ] ++ [ {animal_name, element(2, erl_angry_purple_tiger:animal_name(libp2p_crypto:pubkey_to_b58(PubKey)))} || PubKey /= undefined ],
    lists:foreach(fun(Term) -> io:format("~tp.~n", [Term]) end, Props).

%%
%% Utilities
%%

%% Helper funtion to retry automatic keyslot key generation and
%% locking the first time we encounter an empty keyslot.
get_public_key(ECCPid, Slot) ->
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
            %% key is not present, generate one
            %%
            %% XXX this is really not the best thing to do here
            %% but deadlines rule everything around us
            ok = gen_compact_key(ECCPid, Slot, 100),
            get_public_key(ECCPid, Slot)
    end.

gen_compact_key(_Pid, _Slot, 0) ->
    {error, compact_key_create_failed};
gen_compact_key(Pid, Slot, N) when N > 0 ->
    case  ecc508:genkey(Pid, private, Slot) of
        {ok, PubKey} ->
            case ecc_compact:is_compact(PubKey) of
                {true, _} -> ok;
                false -> gen_compact_key(Pid, Slot, N - 1)
            end;
        {error, Error} ->
            {error, Error}
    end.
