# Chain Variable Transaction 33

## Changes

This transaction revs state channels to version 2.

## Rationale

| Var           	| Existing  	| New 	| Rationale                                             	|
|---------------	|-----------	|-----	|-------------------------------------------------------	|
| sc_version    	| undefined 	| 2   	| State channel version, set to 2                       	|
| sc_overcommit 	| undefined 	| 2   	| State channel amount multiplier when opening channels 	|

## Version threshold

None

## Transaction

```
[{434816,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"sc_overcommit",
                                                     "int",<<"2">>},
                               {blockchain_var_v1_pb,"sc_version","int",<<"2">>}],
                              0,
                              <<48,70,2,33,0,162,15,121,76,214,209,242,208,0,9,221,21,
                                19,161,180,5,9,184,23,205,59,177,237,91,100,156,194,185,
                                80,251,28,152,2,33,0,242,97,20,68,10,53,153,216,139,162,
                                46,141,62,147,173,221,51,213,174,67,43,254,113,155,133,
                                18,192,122,189,233,70,91>>,
                              <<>>,<<>>,[],[],33}]}]
```

## Acceptance block
434816

## Acceptance block time
Tue 28 Jul 2020 04:50:47 PM UTC