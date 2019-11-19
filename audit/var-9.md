# Chain Variable Transaction 9

## Changes

This transaction sets the `poc_rewards` variable from undefined to 2.
Also updates `election_selection_pct` from 60 to 20 and updates `election_removal_pct` from 85 to 40.

## Rationale

A fix to pro-rate non-consensus rewards when elections run long was merged in [blockchain-core#265](https://github.com/helium/blockchain-core/pull/265) and is now being activated. Essentially only the consensus group will see their rewards decline for not doing an election, all other rewards are adjusted from the ideal epoch length to the actual one.

Along with this, we've changed the selection/deselection thresholds for adding and removing members from the consensus group. We've observed it's currently very hard to dislodge consensus members near the top of the list and that the same group of members are consistently being selected. These changes lower the chance that the removed member is at the end of the list, and decreases the chance of picking the absolute top scoring hotspot as the replacement.

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"election_removal_pct","int",
         <<"40">>},
     {blockchain_var_v1_pb,"election_selection_pct","int",
         <<"20">>},
     {blockchain_var_v1_pb,"reward_version","int",<<"2">>}],
    0,
    <<48,69,2,33,0,150,92,253,247,187,93,43,25,69,143,131,147,
      147,135,23,104,164,187,130,18,118,181,179,120,97,30,46,
      12,89,255,156,171,2,32,110,111,190,26,113,252,222,192,
      24,241,183,115,1,43,79,203,113,173,210,140,117,164,242,
      228,39,170,231,40,203,130,41,155>>,
    <<>>,<<>>,[],[],9}
```

## Acceptance block

114600

## Acceptance block time

Monday, 18-Nov-19 22:38:31 UTC
