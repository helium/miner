# Chain Variable Transaction 34

## Changes

This transaction unsets sc_version and sc_overcommit chain variables.

## Rationale

While doing router maintenance the team realized we had stale v1 state channels open with no corresponding close transactions. We cannot activate V2 state channels without ensuring that we have properly cleaned up stale state channels on chain.

| Var           	| Existing 	| New       	| Rationale           	|
|---------------	|----------	|-----------	|---------------------	|
| sc_version    	| 2        	| undefined 	| Unset sc_version    	|
| sc_overcommit 	| 2        	| undefined 	| Unset sc_overcommit 	|


## Version threshold

None

## Transaction

```
[{435153,
  [{blockchain_txn_vars_v1_pb,[],0,
                              <<48,68,2,32,114,100,93,83,190,231,205,4,251,178,196,1,
                                209,228,54,215,210,4,213,25,56,171,133,150,174,137,80,
                                78,223,172,166,32,2,32,15,254,217,100,230,9,24,141,236,
                                119,197,32,176,167,164,73,236,64,126,212,243,93,11,37,
                                23,63,147,193,148,161,199,124>>,
                              <<>>,<<>>,[],
                              [<<"sc_version">>,<<"sc_overcommit">>],
                              34}]}]
```

## Acceptance block
435153

## Acceptance block time
Tue 28 Jul 2020 10:22:39 PM UTC
