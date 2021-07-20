# Chain Variable Transaction 77

## Changes

This transaction sets `staking_keys_to_mode_mappings` to `<<>>` (empty binary) and reduces `poc_challenge_interval` from `480` to `300`.

## Version threshold

None

## Transaction

```
[{930654,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_challenge_interval",
                                                     "int",<<"300">>},
                               {blockchain_var_v1_pb,"staking_keys_to_mode_mappings",
                                                     "binary",<<>>}],
                              0,
                              <<48,69,2,32,116,26,172,104,186,182,41,29,156,220,153,239,
                                171,8,166,241,158,248,175,229,12,190,66,132,196,42,255,
                                164,205,76,213,241,2,33,0,171,127,130,197,238,194,93,77,
                                185,49,51,139,209,135,129,149,155,168,200,87,127,45,135,
                                185,79,233,22,101,9,95,85,212>>,
                              <<>>,<<>>,[],[],77,[],[],[]}]}]
```

## Acceptance block

930654

## Acceptance block time

Tue Jul 20 07:44:21 PM UTC 2021
