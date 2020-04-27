# Chain Variable Transaction 20

## Changes

This transaction enables and tunes elections v3, which now allow consensus members to report their connection quality to other members of the group, and takes these changes into account when selecting a new group.

## Rationale

| Var                     | Existing  | New       | Rationale                                                           |
|-------------------------|-----------|-----------|---------------------------------------------------------------------|
| `election_version`      | 2         | 3         | Enable seen and BBA completion failure penalties                    |
| `election_bba_penalty`  | undefined | 0.001     | BBA failures are common and racy, so their penalty should be lower  |
| `election_seen_penalty` | undefined | 0.0033333 | Seen failures are fairly damning, so their penalty should be higher |


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"election_bba_penalty",
                                                     "float",<<"1.00000000000000002082e-03">>},
                               {blockchain_var_v1_pb,"election_seen_penalty","float",
                                                     <<"3.33329999999999997823e-03">>},
                               {blockchain_var_v1_pb,"election_version","int",<<"3">>}],
                              0,
                              <<48,70,2,33,0,166,120,156,38,174,12,211,181,216,215,165,
                                120,220,184,182,34,145,28,246,25,116,163,2,137,222,252,
                                131,167,84,171,7,98,2,33,0,240,74,53,242,48,71,43,27,
                                159,148,144,231,230,68,127,131,164,99,25,122,198,199,11,
                                7,76,246,221,253,36,219,157,60>>,
                              <<>>,<<>>,[],[],20}
```

## Acceptance block

274998

## Acceptance block time
Thursday, April 2, 2020 8:54:34 PM UTC
