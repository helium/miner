-module(onion_packet_eqc).

-include_lib("eqc/include/eqc.hrl").

-export([prop_onion_packet/0]).

prop_onion_packet() ->
    {ok, ECCBin} = file:read_file("eqc/ecc_compact_keys.bin"),
    %put(ecc_compact, binary_to_term(ECCBin)),
    {ok, ED25519Bin} = file:read_file("eqc/ed25519_keys.bin"),
    %put(ed25519, binary_to_term(ED25519Bin)),
    KeyMap = #{ecc_compact => binary_to_term(ECCBin),
               ed25519 => binary_to_term(ED25519Bin)},

    TestDir = test_utils:tmp_dir("onion_packet_eqc_prop_onion_packet"),
    Ledger = blockchain_ledger_v1:new(TestDir),
    BlockHash = crypto:strong_rand_bytes(32),

    ?FORALL({{KeyType, DataAndKeys}, DecryptOrder}, {gen_data_and_keys(KeyMap), gen_decrypt_order()},
            begin
                OnionKey = libp2p_crypto:generate_keys(KeyType),
                DataVals = [Data || {Data, _Key} <- DataAndKeys],
                ECDHFuns = [libp2p_crypto:mk_ecdh_fun(PvtKey) || {_Data, #{secret := PvtKey}} <- DataAndKeys],
                DataAndBinKeys = [{Key, Data} || {Data, #{public := Key}} <- DataAndKeys],
                %% construct onion in "correct" order
                {Onion, _} = blockchain_poc_packet:build(OnionKey, 1234, DataAndBinKeys, BlockHash, Ledger),
                ShuffledDataAndKeys = shuffle(DataAndKeys, DecryptOrder),
                ShuffledECDHFuns = [libp2p_crypto:mk_ecdh_fun(PvtKey) || {_Data, #{secret := PvtKey}} <- ShuffledDataAndKeys],
                %% decrypt onion in "correct" order
                CorrectDecryption = decrypt_onion(Onion, ECDHFuns, []),
                %% decrypt onion in "generated" order
                OrderedDecryption = decrypt_onion(Onion, ShuffledECDHFuns, []),
                %% figure out how many decryptions we should see after scrambling the list
                PrefixLength = count_common_prefix(DataAndKeys, ShuffledDataAndKeys, 0),
                ?WHENFAIL(begin
                              io:format("Failed~n\tOnion ~w~n\tData ~w~n\tDecrypted ~w~n", [Onion, DataVals, CorrectDecryption]),
                              io:format("ECDHFuns ~p~n", [ECDHFuns])
                          end,
                          conjunction([
                                       {correct_decryption, eqc:equals(DataVals, CorrectDecryption)},
                                       {random_decryption, eqc:equals(lists:sublist(DataVals, PrefixLength),  OrderedDecryption)}
                                      ]))

            end).

count_common_prefix([{_, A}|T1], [{_, B}|T2], Count) when A == B ->
    count_common_prefix(T1, T2, Count+1);
count_common_prefix(_, _, Count) ->
    Count.

shuffle(List, Seed) ->
    rand:seed(exrop, Seed),
    SeededList = [{rand:uniform(length(List)), E} || E <- List],
    [V || {_, V} <- lists:keysort(1, SeededList)].


decrypt_onion(_, [], Acc) ->
    lists:reverse(Acc);
decrypt_onion(<<IV:2/binary,
                OnionCompactKey:33/binary,
                Tag:4/binary,
                CipherText/binary>>, [ECDHFun|Tail], Acc) ->
    case miner_onion_server:try_decrypt(IV, OnionCompactKey, Tag, CipherText, ECDHFun) of
        {error, _} ->
            %io:format("unable to decrypt ~w~n", [CipherText]),
            lists:reverse(Acc);
        {ok, Data, Remainder} ->
            %io:format("next layer ~p~n", [Remainder]),
            decrypt_onion(Remainder, Tail, [Data|Acc])
    end.

gen_decrypt_order() ->
    {eqc_gen:int(), eqc_gen:int(), eqc_gen:int()}.

gen_key_type() ->
    eqc_gen:elements([ecc_compact, ed25519]).

gen_data_and_keys(KeyMap) ->
    ?LET(KeyType, gen_key_type(), {KeyType, ?SUCHTHAT(List, eqc_gen:list(gen_data_and_key(maps:get(KeyType, KeyMap))), length(List) > 2 ) }).

gen_data_and_key(KeyList) ->
    %% XXX all the layer datas have to be the same size right now
    ?LET(Key, eqc_gen:elements(KeyList), {eqc_gen:binary(4), Key}).
