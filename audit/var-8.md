# Chain Variable Transaction 8

## Changes

This transaction sets the `poc_version` variable from undefined to 3.
Also sets the `poc_path_limit` variable from undefined to 7.

## Rationale

The team believes that we are in a good position to reintroduce `poc_path_limit` variable
which essentially limits the proof of coverage challenge paths to 7.

Furthermore, we've bumped `poc_version` to 3, which enables the trigger for better pathing algorithm.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_path_limit",
                                                   "int",<<"7">>},
                             {blockchain_var_v1_pb,"poc_version","int",<<"3">>}],
                            0,
                            <<48,68,2,32,44,50,69,38,69,26,239,88,174,175,9,67,173,90,
                              184,44,56,250,201,63,...>>,
                            <<>>,<<>>,[],[],8}
```

## Acceptance block

89232

## Acceptance block time

Thursday, 17-Oct-19 22:13:16 UTC
