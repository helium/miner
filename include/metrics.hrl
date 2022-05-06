-define(METRICS_HISTOGRAM_BUCKETS, [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000, 60000]).

-define(METRICS_BLOCK_ABSORB, "blockchain_block_absorb_duration").
-define(METRICS_BLOCK_HEIGHT, "blockchain_block_height").

-define(METRICS, #{
    block_metrics => [
        {?METRICS_BLOCK_ABSORB, [blockchain, block, absorb], prometheus_histogram, [stage], "Block absorb duration"},
        {?METRICS_BLOCK_HEIGHT, [blockchain, block, height], prometheus_gauge, [time], "Most recent block height"}
    ]
}).
