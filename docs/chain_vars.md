# chain variables and metadata

### the issue

currently there are settings that are set per node that can break the chain if any of them are changed.  for the stability of the chain we need these to be set on-chain, via some transaction, and have a mechanism for transitioning to using these variables once we're certain that most chain-users will not be busted by the transition.

chain variables include but are not limited to:
- block version
- consensus group size
- PoC interval
- poc ring size
- block interval 
- election interval
- election restart interval
- predicate threshold
- chain variable master key

in short, anything and everything that could make the roll up of blocks into the blockchain non-deterministic if it's different on different nodes needs to be a chain variable, and all checks of these variables must be threaded through the chain variable mechanism with a block height to replay remains deterministic.

##### things we're not trying to do here

this is a MVP for chain transitions without forks; it's not intended to be a generalized mechanism for stakeholders to vote on alternate proposals.  that's somewhat down the road and is political enough of an issue that it shouldn't be tackled without management and product  (and potentially investor) involvement.

### the plan

at the highest level, we'll add a version field to all (or perhaps just poc? anything that a hotspot would propose on its own rather than coming from "outside" the chain) transactions.  this version will be hardcoded in the miner, and will allow the consensus group to verify that some percentage of hotspots have passed a certain point in the history of releases.  we will also add a new transaction type for setting and unsetting variables.

#### transaction details

the transaction will contain a map of key => {type, value}, a list of keys to unset, and an optional version at which it will take effect.  if a version is not set, the transaction will take effect 5 elections after it was accepted to the chain. it may also optionally contain a cancellation of a pending transaction of its type.  if a canceling transaction manages to be accepted on the chain before the transaction it cancels, the cancelled transaction will be ignored.

###### variable details

variables are single, flat values of type `string` (`list`, `iolist`, or `binary`), `int`, `float`, or `atom`.  since we're not particularly concerned about efficiency here, everything is serialized as its string representation).  variable maps are merged with prior maps after any unset actions have been processed.

###### transaction validity

if the block is the genesis block, the transaction is only valid if it contains a key called master_key which points to a string containing a public key.

any transaction containing a `master_key`, including the genesis block, but include a `key_proof` binary, which is the same as a normal `proof`, but for the new master key.  this is to make sure that the key is real and valid and that the chain will not be permanently locked. `proof` is not required for the genesis block, but both `key_proof` and `proof` must be present and valid for a key transition.

any subsequent transactions of this type must be signed by the master key.  the signed artifact is the `[{compressed, 9}]` serialization of the erlang map resulting from this transaction.  this is not amazingly friendly to other languages, but ETF libraries are available for many other languages.

###### upgrade details.

NB: there is no commit transaction required for vars txns without a
version predicate.  they are considered to be committed immediately,
and will take effect after a suitable interval

at each election, if there are pending chain variable changes, we look at the version of each active gateway to determine if the network meets the threshold value for committing to the chain variable update.  if so, a committed transaction pointing to the update is added with the current election epoch and the epoch at which the change will become effective.  the race here means that chain variable updates that change the size of the consensus group will not take effect until the next election after the one at which the change takes effect (e.g. if the txn that changes group size from 7 to 13 is committed in epoch 45, the election at epoch 50 will be of size 7 still, but the chain variables changes will go into effect at 50.  at epoch 51, the consensus size for the election will be 13).
