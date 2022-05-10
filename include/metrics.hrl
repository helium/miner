-define(METRICS_HISTOGRAM_BUCKETS, [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000, 60000]).

-define(METRICS_BLOCK_ABSORB, "blockchain_block_absorb_duration").
-define(METRICS_BLOCK_HEIGHT, "blockchain_block_height").
-define(METRICS_GRPC_SESSIONS, "grpcbox_session_count").
-define(METRICS_GRPC_LATENCY, "grpcbox_session_latency").

-define(METRICS, #{
    block_metrics => {
        [ [blockchain, block, absorb],
          [blockchain, block, height] ],
        [ {?METRICS_BLOCK_ABSORB, prometheus_histogram, [stage], "Block absorb duration"},
          {?METRICS_BLOCK_HEIGHT, prometheus_gauge, [time], "Most recent block height"} ]
    },
    grpc_metrics => {
        [ [grpcbox, server, rpc_begin],
          [grpcbox, server, rpc_end] ],
        [ {?METRICS_GRPC_SESSIONS, prometheus_gauge, [method], "Grpc session count"},
          {?METRICS_GRPC_LATENCY, prometheus_histogram, [method, status], "Grpc session latency"} ]
    }
}).
