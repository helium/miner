# Chain Variable Transaction 8

## Changes

This transaction sets the `poc_rewards` variable from undefined to 2.
Also updates `election_selection_pct` from 60 to 20 and updates `election_removal_pct` from 85 to 40.

## Rationale

A fix to pro-rate non-consensus rewards when elections run long was merged in [blockchain-core#265](https://github.com/helium/blockchain-core/pull/265) and is now being activated. Essentially only the consensus group will see their rewards decline for not doing an election,all other rewards are adjusted from the ideal epoch length to the actual one.

Along with this, we've changed the selection/deselection thresholds for adding and removing members from the consensus group. We've observed it's currently very hard to dislodge consensus members near the top of the list and that the same group of members are consistently being selected. These changes lower the chance that the removed member is at the end of the list, and decreases the chance of picking the absolute top scoring hotspot as the replacement.

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

114600

## Acceptance block time

Monday, 18-Nov-19 22:38:31 UTC
