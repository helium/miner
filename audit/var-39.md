# Chain Variable Transaction 39

## Changes

This transaction changes the `sc_grace_blocks` chain variable from 20 to 10, essentially allowing faster open/close of state channels.

## Rationale

| Var                     	| Existing 	| New    	| Rationale                               	|
|-------------------------	|----------	|--------	|-----------------------------------------	|
| sc_grace_blocks       	| 20      	| 10       	| Reduced to allow faster open/close of SC	|

## Version threshold

None

## Transaction

```
[{454211,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"sc_grace_blocks","int",<<"10">>}],
       0,
       <<48,70,2,33,0,191,192,56,34,57,11,36,171,34,6,131,168,71,
         200,101,233,239,219,113,112,167,169,49,146,161,159,132,
         26,251,165,218,50,2,33,0,224,221,49,130,47,207,158,223,
         248,56,192,78,118,216,109,255,245,70,69,2,110,250,111,
         11,211,203,251,2,139,149,9,29>>,
       <<>>,<<>>,[],[],39}]}]
```

## Acceptance block

454211


## Acceptance block time

Thu 13 Aug 2020 12:56:16 AM UTC