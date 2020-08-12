# Chain Variable Transaction 38

## Changes

This transaction changes the token distribution in accordance with the values listed below.

## Rationale

| Var                     	| Existing 	| New    	| Rationale                               	|
|-------------------------	|----------	|--------	|-----------------------------------------	|
| consensus_percent       	| 0.1      	| 0.06   	| Reduced to accomodate dc_percent        	|
| dc_percent              	| 0        	| 0.325  	| Introduced to charge for packet routing 	|
| poc_challengers_percent 	| 0.15     	| 0.0095 	| Reduced to acocomdate dc_percent        	|
| poc_challengees_percent 	| 0.35     	| 0.18   	| Reduced to accomodate dc_percent        	|
| securities_percent      	| 0.35     	| 0.34   	| Reduced to accomodate dc_percent        	|
| poc_witnesses_percent   	| 0.05     	| 0.0855 	| Increased to accomodate dc_percent      	|


## Version threshold

None

## Transaction

```
[{453939,
  [{blockchain_txn_vars_v1_pb,
       [{blockchain_var_v1_pb,"consensus_percent","float",
            <<"5.99999999999999977796e-02">>},
        {blockchain_var_v1_pb,"dc_percent","float",
            <<"3.25000000000000011102e-01">>},
        {blockchain_var_v1_pb,"poc_challengees_percent","float",
            <<"1.79999999999999993339e-01">>},
        {blockchain_var_v1_pb,"poc_challengers_percent","float",
            <<"9.49999999999999976408e-03">>},
        {blockchain_var_v1_pb,"poc_witnesses_percent","float",
            <<"8.55000000000000065503e-02">>},
        {blockchain_var_v1_pb,"securities_percent","float",
            <<"3.40000000000000024425e-01">>}],
       0,
       <<48,68,2,32,23,20,42,83,176,255,107,148,207,179,60,134,
         119,66,84,132,106,192,38,222,157,69,194,214,57,214,117,
         244,63,202,50,213,2,32,92,31,148,182,67,227,220,167,0,
         167,136,80,85,127,218,22,172,43,14,34,114,39,4,170,247,
         105,137,158,69,196,227,148>>,
       <<>>,<<>>,[],[],38}]}]
```

## Acceptance block

453939

## Acceptance block time

Wed 12 Aug 2020 07:12:11 PM UTC