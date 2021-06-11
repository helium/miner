# Chain Variable Transaction 64

## Changes

This transaction changes `witness_refresh_interval` from `20000` to `3000` to help reduce write wear on SD cards and refresh witness lists faster.

## Version threshold

None

## Transaction

```
[{872385,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"witness_refresh_interval",
                                                     "int",<<"3000">>}],
                              0,
                              <<48,69,2,32,55,32,77,39,188,11,76,68,113,6,1,218,166,23,
                                132,145,99,233,197,230,65,78,180,148,37,200,50,215,85,
                                12,225,169,2,33,0,153,230,127,149,16,180,216,255,200,86,
                                82,47,20,8,140,115,66,66,125,172,210,81,189,172,147,213,
                                94,207,141,23,186,15>>,
                              <<>>,<<>>,[],[],64,[],[],[]}]}]

```

## Acceptance block

872385

## Acceptance block time

Sun Jun  6 12:38:04 AM UTC 2021
