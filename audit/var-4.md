# Chain Variable Transaction 3

## Changes

This transaction changes the `monthly_reward` variable to 500000000000000 from 5000000000000.

Additionally, the `chain_vars_version` is set to 2 to reflect a refactor of both the encoding of the variable update and improving the verification of chain var updates.

## Rationale

In the genesis block, there an error was made.  The initial `monthly_reward` was set to 50000000000.  Because of this, tokens are mined at a rate that is one hundred times too slow.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"chain_vars_version","int",<<"2">>},
     {blockchain_var_v1_pb,"monthly_reward","int",
         <<"500000000000000">>}],
    0,
    <<48,68,2,32,17,100,106,113,165,178,37,220,116,219,253,
      173,218,37,72,209,247,151,55,240,102,115,228,128,223,
      214,233,209,96,220,140,196,2,32,111,81,109,42,20,196,
      189,29,181,133,155,196,205,41,13,184,104,113,10,211,185,
      86,238,124,68,53,106,194,57,113,13,4>>,
    <<>>,<<>>,[],[],4}
```

## Acceptance block

TBA
