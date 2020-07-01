# Chain Variable Transaction 31

## Changes

This transaction limits how many Hotspots are considered in either targeting or pathing steps when constructing or validating a poc transaction.
This limits how many things we have to pull off the disk, which was causing transactions to take ages to process.

## Rationale

| Var                           	| Existing  	| New           	| Rationale                                                               	|
|-------------------------------	|-----------	|---------------	|-------------------------------------------------------------------------	|
| poc_witness_consideration_limit | undefined | 20 | When there are many Hotspots to consider, choose a deterministically random subset to consider instead |


## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
    [{blockchain_var_v1_pb,"poc_witness_consideration_limit", 
         "int",<<"20">>}],
    0,
    <<48,70,2,33,0,232,191,56,187,233,34,44,199,75,184,155,
      156,62,84,52,201,120,215,246,178,168,16,47,143,39,17,
      196,32,85,147,68,93,2,33,0,159,37,171,56,219,16,110,64,
      114,161,153,200,166,141,227,30,202,231,57,208,209,27,
      129,146,82,150,150,113,117,214,181,138>>,
    <<>>,<<>>,[],[],31}]}]
```

## Acceptance block
395603

## Acceptance block time
Wed 01 July 2020 05:13:16 PM UTC
