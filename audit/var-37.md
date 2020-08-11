# Chain Variable Transaction 37

## Changes

This transaction increments `max_open_sc` chain var from 2 to 3.

## Rationale

| Var           	| Existing  	| New 	| Rationale                                             	|
|---------------	|-----------	|-----	|-------------------------------------------------------	|
| max_open_sc    	| 2         	| 3   	| Allow router to open maximum 3 state channels at a time  	|

## Version threshold

None

## Transaction

```
[{452178,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"max_open_sc","int",<<"3">>}],
       0,
       <<48,69,2,32,123,137,238,41,42,193,113,235,205,22,232,216,
         58,118,182,103,247,134,195,130,46,162,156,15,228,176,47,
         253,50,34,100,169,2,33,0,166,147,64,101,79,33,51,202,
         123,115,120,79,54,231,203,225,109,230,36,31,120,250,29,
         169,244,10,6,150,218,196,207,54>>,
       <<>>,<<>>,[],[],37}]}]
```

## Acceptance block

452178

## Acceptance block time

Tue 11 Aug 2020 03:09:50 AM UTC