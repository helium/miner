# Chain Variable Transaction 2

## Changes

This transaction changes the `election_restart_interval` variable to 5 from 10.

## Rationale

With the current health of the network, consensus group size of 16,  and sixty second block time, we believe that approximately five minutes is more than enough time for an election process to complete with a healthy group.  Lowering the restart time will allow us to try more groups to find a currently healthy one and should lower election delay.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
 [{blockchain_var_v1_pb,"election_restart_interval",
   "int",<<"5">>}],
 0,
 <<48,68,2,32,107,138,139,142,174,184,147,41,146,90,67,214,
   6,32,90,17,164,246,195,182,29,53,188,60,205,233,122,252,
   38,88,181,153,2,32,22,243,104,99,66,232,176,98,42,74,
   148,225,5,240,113,131,24,250,22,5,156,200,18,101,179,52,
   231,255,148,206,12,75>>,
 <<>>,<<>>,[],[],2}
```

## Acceptance block

4816

## Acceptance block time

Friday, 02-Aug-19 17:07:18 UTC
