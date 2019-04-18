## elections

### overall design

The asynchronous election design is fairly simple.  Every `interval` blocks, an election is started.  A dkg is run, and if it does not complete within `election_timeout` it's canceled, and a new one is run with a different set of nodes.  Eventually a dkg completes, and a new group transaction is generated and transmitted to the existing consensus group.  The starting height is encoded in this transaction so it can be proven.  Once the block is accepted into the consensus group, the old group shuts down and the new group becomes the main mining group.  We encode the epoch change and current round into the new block (which can be confusing, as it encodes a different height than the transaction, but for fairness, we start the clock running when the transaction is accepted, so that each group gets _at least_ `interval` rounds before it expires) to help with restores.  From there, the new group produces `interval` new blocks until it too expires, and the process repeats.

### restore

Restoration from start is where things get really complicated.  No matter what is going on, we need to be able to restart a working consensus group so that the chain can proceed.  We work through the large number of cases below.

#### design

We encode the epoch and election start height into each block.  This should allow a fully synced node to make the proper decision about what it should be doing when it gets a new, non-sync block.

The common case will be to check the election height of the current block and see if an election could be running, then if so, start one.  Then the node should check if it should be (or was) part of the current consensus group.  We could make this easier by making groups-on-disk queryable in the consensus manager, but right now we just try to start the appropriate group, and if it's there, great.

#### cold start

This is the extremely rare case where a large number of fully up-to-date consensus nodes are offline during an ongoing election, up to and including the entire quorum.  We handle this via a timer on start, which fires only if we are not getting blocks, and attempts to run through the design above.

#### non-consensus restore

Assuming that we're not up to date, we sync and process blocks, potentially starting a number of elections and/or consensus blocks along the way.  This could be improved by knowing the ultimate height of the chain when we start up, and only starting the last few which matter.  While we do start a consensus group init process, it never starts because we're not part of it. Once we're synced and have made sure that no election or group that we're part of is running, we're a normal node.

#### consensus restore

Similarly to the above, we sync and start up a number of groups along the way, but this time we start up the appropriate consensus group and all the sudden we're mining blocks.

#### in-progress consensus restore

The above is complicated by the fact that we could have gone down *after* the block where we would have started group, so when we're fully synced, we do have to try to start a consensus round for the current epoch.

#### consensus restore with active election

Similarly to consensus groups, we need to check if we're part of the election group if one could be in progress.  We calculate this with a height check from the start of the current epoch.
