# Chain Variable Transaction 4

## Changes

This transaction changes the `monthly_reward` variable to 500000000000000 from 5000000000000.

Additionally, the `chain_vars_version` is set to 2.

## Rationale

The increase of the monthly reward to 5,000,000 per month is a strategic one, concerning potential purchasers who might be uncomfortable buying tiny fractions of the headline token amount.

The chain vars version bump addresses some verifications shortcomings in the initial implementation of chain vars that would allow previous transactions to be replayed.  This new version prevents that and a related attack on the chain, and this change activates it.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"chain_vars_version","int",<<"2">>},
     {blockchain_var_v1_pb,"monthly_reward","int",
         <<"500000000000000">>}],
    0,
    <<48,70,2,33,0,150,209,97,188,21,114,247,76,119,124,54,47,
      166,32,33,107,219,134,154,201,155,46,104,8,238,122,159,
      133,22,206,168,229,2,33,0,205,146,25,194,191,110,207,
      216,18,118,148,158,22,16,145,198,38,75,185,21,64,226,
      187,150,59,160,144,162,168,164,120,159>>,
    <<>>,<<>>,[],[],4}
```

## Acceptance block

10371 

## Acceptance block time

Wednesday, 07-Aug-19 22:13:50 UTC
