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
 <<48,68,2,32,118,1,81,145,125,116,114,20,240,84,35,74,209,
   170,159,162,231,79,182,145,3,...>>,
   <<>>,<<>>,[],[],3}
```

## Acceptance block


