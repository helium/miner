# Chain Variable Transaction 40

## Changes

This transaction updates and introduces a few new chain variables to address some of the concerns we've had over the past few weeks regarding state channels v2.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| max_open_sc               	| 3         	| 5   	| Increased total number of state channels a router can open at a given time 	|
| sc_causality_fix          	| undefined 	| 1   	| Introduced to disable duplicate state channel close txns                   	|
| sc_gc_interval            	| undefined 	| 10  	| Introduced to allow faster garbage collection of closed state channels     	|
| sc_open_validation_bugfix 	| undefined 	| 1   	| Introduced to fix a potential invalid state channel open bug               	|


## Version threshold

None

## Transaction

```
[{456072,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"max_open_sc",
                                                     "int",<<"5">>},
                               {blockchain_var_v1_pb,"sc_causality_fix","int",<<"1">>},
                               {blockchain_var_v1_pb,"sc_gc_interval","int",<<"10">>},
                               {blockchain_var_v1_pb,"sc_open_validation_bugfix","int",
                                                     <<"1">>}],
                              0,
                              <<48,70,2,33,0,210,249,8,31,125,146,163,121,96,46,140,245,
                                115,109,169,82,146,225,56,215,146,139,229,46,69,40,51,
                                242,218,116,78,225,2,33,0,176,218,89,140,187,230,32,219,
                                230,37,76,134,160,70,189,18,239,206,112,112,116,25,48,
                                30,213,251,158,221,16,118,67,188>>,
                              <<>>,<<>>,[],[],40}]}]
```

## Acceptance block

456072

## Acceptance block time

Fri 14 Aug 2020 05:55:17 PM UTC