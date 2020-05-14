# Chain Variable Transaction 22

## Changes

This transaction enables state channel related transactions on chain.

## Rationale

| Var                 	| Existing  	| New    	| Rationale                                                    	|
|---------------------	|-----------	|--------	|--------------------------------------------------------------	|
| dc_payload_size     	| undefined 	| 24     	| Payload size for calculating data credits                    	|
| max_open_sc         	| undefined 	| 2      	| Maximum open state channels per router                       	|
| min_expire_within   	| undefined 	| 15     	| Minimum state channel expiration, set in number of blocks    	|
| max_xor_filter_size 	| undefined 	| 102400 	| Maximum XOR filter size, required for routing                	|
| max_xor_filter_num  	| undefined 	| 5      	| Maximum number of xor filters a router may have              	|
| min_subnet_size     	| undefined 	| 8      	| Minimum subnet size                                          	|
| sc_grace_blocks     	| undefined 	| 100    	| Number of blocks for garbage collecting stale state channels 	|
| max_subnet_num      	| undefined 	| 5      	| Maximum number of subnets a router may have                  	|
| max_subnet_size     	| undefined 	| 65536  	| Maximum size of the subnet                                   	|


## Version threshold

None

## Transaction

```
[{330652,
  [{blockchain_txn_vars_v1_pb,[{blockchain_var_v1_pb,"dc_payload_size",
                                                     "int",<<"24">>},
                               {blockchain_var_v1_pb,"max_open_sc","int",<<"2">>},
                               {blockchain_var_v1_pb,"max_subnet_num","int",<<"5">>},
                               {blockchain_var_v1_pb,"max_subnet_size","int",<<"65536">>},
                               {blockchain_var_v1_pb,"max_xor_filter_num","int",<<"5">>},
                               {blockchain_var_v1_pb,"max_xor_filter_size","int",
                                                     <<"102400">>},
                               {blockchain_var_v1_pb,"min_expire_within","int",<<"15">>},
                               {blockchain_var_v1_pb,"min_subnet_size","int",<<"8">>},
                               {blockchain_var_v1_pb,"sc_grace_blocks","int",<<"100">>}],
                              0,
                              <<48,69,2,33,0,133,198,15,168,236,240,77,226,40,153,11,
                                222,123,102,228,201,225,214,161,188,69,39,126,59,109,79,
                                204,117,220,63,60,32,2,32,78,26,181,170,40,1,165,120,8,
                                222,249,249,66,141,157,8,53,145,200,66,137,41,46,107,
                                134,103,74,163,41,105,201,179>>,
                              <<>>,<<>>,[],[],22}]}]

```

## Acceptance block

330652

## Acceptance block time
Tue 12 May 2020 07:29:17 PM UTC
