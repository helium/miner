# Chain Variable Transaction 3

## Changes

This transaction changes the `monthly_reward` variable to 5000000000000 from 50000000000.

## Rationale

In the genesis block, there an error was made.  The initial `monthly_reward` was set to 50000000000.  Because of this, tokens are mined at a rate that is one hundred times too slow.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"monthly_reward","int",
         <<"5000000000000">>}],
    0,
    <<48,68,2,32,24,78,173,139,96,93,22,38,189,104,85,19,213,
      224,74,116,89,1,14,31,176,148,62,11,69,17,14,3,154,207,
      70,125,2,32,84,184,71,55,100,56,155,254,85,236,102,2,
      251,154,0,190,171,207,39,51,5,74,51,193,181,133,79,85,
      43,14,40,127>>,
    <<>>,<<>>,[],[],3}
```

## Acceptance block

6116

## Acceptance block time

Saturday, 03-Aug-19 16:22:42 UTC
