# Chain Variable Transaction 35

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
[{436410,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"sc_overcommit",
                                                     "int",<<"2">>},
                               {blockchain_var_v1_pb,"sc_version","int",<<"2">>}],
                              0,
                              <<48,70,2,33,0,214,118,106,99,186,169,129,209,74,144,214,
                                135,29,126,221,200,203,141,32,202,110,157,112,72,72,57,
                                47,45,249,178,10,85,2,33,0,209,197,206,176,93,141,206,
                                126,232,143,203,108,93,237,136,218,64,127,86,213,59,216,
                                5,20,203,54,222,233,191,237,26,255>>,
                              <<>>,<<>>,[],[],35}]}]
```

## Acceptance block
436410

## Acceptance block time
Wed 29 Jul 2020 06:14:24 PM UTC
