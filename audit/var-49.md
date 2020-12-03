# Chain Variable Transaction 49

## Changes

This transaction updates `poc_challenge_interval` from `120` to `240`.

## Rationale

| Var                       	        | Existing  	| New 	| Rationale                                                                  	|
|---------------------------	        |-----------	|-----	|----------------------------------------------------------------------------	|
| poc_challenge_interval      	        | 120         	| 240  	| Increased to allow consistent block times                                     |


## Version threshold

None

## Transaction

```
[{613619,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"poc_challenge_interval",
                                                     "int",<<"240">>}],
                              0,
                              <<48,69,2,33,0,196,248,77,187,121,177,236,77,203,171,226,
                                51,179,72,20,251,34,248,94,108,2,100,70,5,58,233,139,
                                153,102,147,251,82,2,32,108,143,146,110,164,41,57,88,0,
                                159,206,213,18,143,160,215,156,71,33,27,26,61,152,78,86,
                                44,95,147,64,106,246,27>>,
                              <<>>,<<>>,[],[],49,[],[],[]}]}]
```

## Acceptance block

613619

## Acceptance block time

Thu Dec  3 12:03:48 AM UTC 2020
