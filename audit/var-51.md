# Chain Variable Transaction 51

## Changes

This transaction increments the maximum number of witnesses allowed for a PoC beacon from 5 to 25.

## Rationale


| Chain Variable             |      Old Value        |      New Value        | Reason                                                                  |
|----------------------------|-----------------------|-----------------------|-------------------------------------------------------------------------|
| poc_per_hop_max_witnesses  |      undefined        |         25            | Previously defaulted to 5, incremented to allow more witnesses          |


## Version threshold

None

## Transaction

```
[{635457,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_per_hop_max_witnesses",
                                                     "int",<<"25">>}],
                              0,
                              <<48,68,2,32,80,206,94,61,218,145,126,175,123,225,31,12,
                                166,176,193,113,220,252,33,134,16,137,38,172,216,165,
                                238,74,170,54,39,136,2,32,122,126,29,183,41,157,97,148,
                                67,26,224,215,7,198,75,58,251,243,95,31,13,79,147,246,
                                202,87,23,216,0,225,105,96>>,
                              <<>>,<<>>,[],[],51,[],[],[]}]}]
```

## Acceptance block

635457

## Acceptance block time

Wed Dec 16 11:07:41 PM UTC 2020
