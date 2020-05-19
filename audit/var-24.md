# Chain Variable Transaction 24

## Changes

We mistakenly introduced a drift between the lagging ledger and current ledger with the previous chain variable txn.
This transaction unsets the following chain variables we believe to be the cause of the issue.

## Rationale

| Var                      	| Existing  	| New   	| Rationale                                                                    	|
|--------------------------	|-----------	|-------	|------------------------------------------------------------------------------	|
| witness_refresh_interval 	| 10080 	    | undefined	| Reset back to undefined                  	                                    |
| witness_refresh_rand_n   	| 1000 	        | undefined	| Reset back to undefined                                                       |

## Version threshold

None

## Transaction

```
[{339291,
  [{blockchain_txn_vars_v1_pb,[],0,
                              <<48,69,2,33,0,157,203,175,135,113,219,89,82,47,57,241,
                                132,10,214,204,109,...>>,
                              <<>>,<<>>,[],
                              [<<"witness_refresh_interval">>,
                               <<"witness_refresh_rand_n">>],
                              24}]}]
```

## Acceptance block
339291

## Acceptance block time
Tue 19 May 2020 12:44:13 AM UTC
