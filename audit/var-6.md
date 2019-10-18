# Chain Variable Transaction 6

## Changes

This transaction unsets the `poc_path_limit` variable from 7.

## Rationale

Since the introduction of `Chain Variable Transaction 5`, we've noticed inconsistent block production.
This transaction is the first attempt to rollback the network to a good working state and help Helium root cause the issue.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[],0,
       <<48,69,2,33,0,194,248,26,243,194,211,146,118,145,226,128,114,43,112,
         142,110,136,145,15,147,171,180,94,151,22,196,242,97,199,244,246,19,2,
         32,99,46,176,214,212,80,245,252,86,161,90,103,37,141,84,203,84,248,
         146,199,124,42,100,95,172,0,255,174,75,116,244,8>>,
       <<>>,<<>>,[],
       [<<"poc_path_limit">>],
       6}
```

## Acceptance block

82251

## Acceptance block time

Friday, 11-Oct-19 06:21:33 UTC
