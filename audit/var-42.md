# Chain Variable Transaction 42

## Changes

This transaction updates `poc_challenge_interval` from 60 to 120 to improve chain stability and block times.


## Rationale

| Var                       	| Existing  	| New 	| Rationale                                                                  	|
|---------------------------	|-----------	|-----	|----------------------------------------------------------------------------	|
| poc_challenge_interval      	| 60         	| 120  	| Incremented to improve chain stability and block times                        |


## Version threshold

None

## Transaction

```
[{479241,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"poc_challenge_interval","int",
            <<"120">>}],
       0,
       <<48,69,2,33,0,165,214,204,198,109,171,27,5,46,168,142,75,
         225,183,230,2,198,81,217,144,202,47,137,199,145,185,49,
         248,156,20,96,154,2,32,49,194,198,76,38,128,182,130,163,
         39,212,204,243,242,187,240,145,2,53,17,35,27,129,178,9,
         25,204,217,117,248,29,0>>,
       <<>>,<<>>,[],[],42}]}]
```

## Acceptance block

479241

## Acceptance block time

Wed Sep  2 10:47:08 PM UTC 2020