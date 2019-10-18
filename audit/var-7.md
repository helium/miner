# Chain Variable Transaction 7

## Changes

This transaction unsets the `poc_version` variable from 2.

## Rationale

Since the introduction of `Chain Variable Transaction 5`, we've noticed inconsistent block production.
This transaction is the second attempt to rollback the network to a good working state and help Helium root cause the issue.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[],0,
                              <<48,69,2,32,81,242,110,255,110,69,147,153,128,
                                102,109,177,73,38,179,217,161,5,127,5,246,88,
                                189,166,47,177,33,151,107,62,20,95,2,33,0,226,
                                114,191,6,75,74,148,113,111,72,80,195,101,66,
                                101,27,63,238,30,54,229,147,212,155,2,213,27,
                                95,219,130,229,199>>,
                              <<>>,<<>>,[],
                              [<<"poc_version">>],
                              7}
```

## Acceptance block

82537

## Acceptance block time

Saturday, 12-Oct-19 02:11:04 UTC
