# Chain Variable Transaction 66

## Changes

This transaction changes `witness_refresh_interval` from `3000` to `1` to help further reduce write wear on SD cards and refresh witness lists faster.

## Version threshold

None

## Transaction

```
[{883834,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"witness_refresh_interval",
                                                     "int",<<"1">>}],
                              0,
                              <<48,70,2,33,0,252,89,220,89,131,226,59,76,87,27,106,194,
                                213,210,122,188,127,233,227,116,21,1,176,170,239,100,
                                150,11,80,193,173,137,2,33,0,191,163,190,1,121,10,161,
                                212,223,107,150,95,61,39,11,92,101,106,97,172,43,1,175,
                                110,203,49,208,225,182,237,197,88>>,
                              <<>>,<<>>,[],[],66,[],[],[]}]}]

```

## Acceptance block

883834

## Acceptance block time

Tue Jun 15 04:58:05 PM UTC 2021
