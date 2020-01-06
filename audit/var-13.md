# Chain Variable Transaction 13

## Changes

This transaction updates `poc_version` from 5 to 6.
Also introudces `poc_typo_fixes` chain variable and sets it to `true`.

## Rationale

| Var            | Old       | New  | Rationale                                                                       |
|----------------|-----------|------|---------------------------------------------------------------------------------|
| poc_version    | 5         | 6    | Update poc version to disallow pathing with known impossible RSSI values        |
| poc_typo_fixes | undefined | true | Ensure we mask the typo fixes behind this chain variable to not break consensus |

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_typo_fixes",
                                                   "atom",<<"true">>},
                             {blockchain_var_v1_pb,"poc_version","int",<<"6">>}],
                            0,
                            <<48,69,2,32,34,221,215,207,79,246,139,252,54,174,189,227,
                              142,143,253,198,229,72,101,130,35,144,95,120,169,1,84,
                              50,108,251,160,88,2,33,0,163,175,215,210,19,197,159,228,
                              187,229,159,65,25,26,141,13,241,68,5,92,234,33,35,133,
                              216,181,173,7,56,117,184,239>>,
                            <<>>,<<>>,[],[],13}
```

## Acceptance block

164508

## Acceptance block time

Mon 06 Jan 2020 09:17:48 PM UTC
