# Chain Variable Transaction 5

## Changes

This change introduces:
`poc_version`
`poc_path_limit`
`poc_challenge_sync_interval`
`election_version`
`election_removal_pct`
`election_cluster_res`

And updates:
`alpha_decay`
`beta_decay`
`election_selection_pct`

chain variables.

## Rationale

|Var                            | Old       | New   | Rationale                                                                             |
|-------------------------------|-----------|-------|---------------------------------------------------------------------------------------|
|poc_version                    |undefined  |2      |activates witness data collection in ledger                                            |
|poc_path_limit                 |undefined  |7      |limit poc path lengths to 7                                                            |
|alpha_decay                    |0.007      |0.0035 |allow high scoring hotspots to stay high for ~1 day                                    |
|beta_decay                     |0.0005     |0.002  |allow low scoring hotspots to gain score back to 0.25 in ~1.5 days                     |
|poc_challenge_sync_interval    |undefined  |90     |don't challenge new hotspots till they have synced within 90 blocks of latest height   |
|election_version               |undefined  |2      |activate updated election logic                                                        |
|election_selection_pct         |75         |60     |probability a hotspot gets selected from a score-sorted list of non-consensus hotspots |
|election_removal_pct           |undefined  |85     |probability a hotspot gets removed from a score-sorted list of consensus hotspots      |
|election_cluster_res           |undefined  |8      |enable geographically diverse elections                                                |

## Version threshold

None

## Transaction

```
{blockchain_txn_vars_v1_pb,
   [{blockchain_var_v1_pb,"alpha_decay","float",
        <<"3.50000000000000007286e-03">>},
    {blockchain_var_v1_pb,"beta_decay","float",
        <<"2.00000000000000004163e-03">>},
    {blockchain_var_v1_pb,"election_cluster_res","int",<<"8">>},
    {blockchain_var_v1_pb,"election_removal_pct","int",<<"85">>},
    {blockchain_var_v1_pb,"election_selection_pct","int",<<"60">>},
    {blockchain_var_v1_pb,"election_version","int",<<"2">>},
    {blockchain_var_v1_pb,"poc_challenge_sync_interval","int",<<"90">>},
    {blockchain_var_v1_pb,"poc_path_limit","int",<<"7">>},
    {blockchain_var_v1_pb,"poc_version","int",<<"2">>}],
   0,
   <<48,69,2,33,0,225,32,84,76,191,14,74,10,251,109,157,231,168,46,111,159,
     187,147,230,0,236,115,148,125,238,57,17,110,92,233,103,122,2,32,29,80,
     2,243,13,105,214,33,130,21,69,223,20,54,39,111,168,66,136,250,149,95,
     106,189,2,182,139,38,119,6,155,109>>,
   <<>>,<<>>,[],[],5},
```

## Acceptance block

82039 

## Acceptance block time

Thursday, 10-Oct-19 19:17:29 UTC
