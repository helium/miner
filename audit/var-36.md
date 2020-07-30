# Chain Variable Transaction 36

## Changes

This transaction reduces `sc_grace_blocks` from 100 to 20 to allow for faster cleanup of pending state_channel_close transactions.

## Rationale

| Var           	| Existing  	| New 	| Rationale                                             	|
|---------------	|-----------	|-----	|-------------------------------------------------------	|
| sc_grace_blocks 	| 100        	| 20   	| Reduced to allow faster GC for closing state channels    	|

## Version threshold

None

## Transaction

```
[{438127,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"sc_grace_blocks",
                                                     "int",<<"20">>}],
                              0,
                              <<48,69,2,33,0,149,117,122,204,183,199,139,189,15,109,219,
                                95,133,26,247,5,138,109,29,194,191,31,36,174,86,240,112,
                                55,201,144,241,92,2,32,98,63,202,200,95,149,209,50,30,
                                250,164,41,60,127,115,5,52,179,10,203,238,115,92,197,
                                129,110,21,51,92,173,211,91>>,
                              <<>>,<<>>,[],[],36}]}]
```

## Acceptance block

438127

## Acceptance block time
Thu 30 Jul 2020 11:35:35 PM UTC