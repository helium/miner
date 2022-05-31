-define(METRICS_HISTOGRAM_BUCKETS, [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000, 60000]).

-define(METRICS_BLOCK_ABSORB, "blockchain_block_absorb_duration").
-define(METRICS_BLOCK_UNVAL_ABSORB, "blockchain_block_unval_absorb_duration").
-define(METRICS_BLOCK_HEIGHT, "blockchain_block_height").
-define(METRICS_BLOCK_UNVAL_HEIGHT, "blockchain_block_unval_height").
-define(METRICS_TXN_ABSORB_DURATION, "blockchain_txn_absorb_duration").
-define(METRICS_TXN_SUBMIT_COUNT, "blockchain_txn_mgr_submited_count").
-define(METRICS_TXN_REJECT_COUNT, "blockchain_txn_mgr_rejected_count").
-define(METRICS_TXN_REJECT_SPAN, "blockchain_txn_mgr_rejected_span").
-define(METRICS_TXN_ACCEPT_COUNT, "blockchain_txn_mgr_accepted_count").
-define(METRICS_TXN_ACCEPT_SPAN, "blockchain_txn_mgr_accepted_span").
-define(METRICS_TXN_PROCESS_DURATION, "blockchain_txn_mgr_process_duration").
-define(METRICS_TXN_CACHE_SIZE, "blockchain_txn_mgr_cache_size").
-define(METRICS_TXN_BLOCK_TIME, "blockchain_txn_mgr_block_time").
-define(METRICS_TXN_BLOCK_AGE, "blockchain_txn_mgr_block_age").
-define(METRICS_GRPC_SESSIONS, "grpcbox_session_count").
-define(METRICS_GRPC_LATENCY, "grpcbox_session_latency").
-define(METRICS_SC_COUNT, "blockchain_state_channel_count").
-define(METRICS_SNAP_LOAD_SIZE, "blockchain_snapshot_load_size").
-define(METRICS_SNAP_LOAD_DURATION, "blockchain_snapshot_load_duration").
-define(METRICS_SNAP_GEN_SIZE, "blockchain_snapshot_gen_size").
-define(METRICS_SNAP_GEN_DURATION, "blockchain_snapshot_gen_duration").

-define(METRICS, #{
    block_metrics => {
        [ [blockchain, block, absorb],
          [blockchain, block, height],
          [blockchain, block, unvalidated_absorb],
          [blockchain, block, unvalidated_height] ],
        [ {?METRICS_BLOCK_ABSORB, prometheus_histogram, [stage], "Block absorb duration"},
          {?METRICS_BLOCK_HEIGHT, prometheus_gauge, [time], "Most recent block height"},
          {?METRICS_BLOCK_UNVAL_ABSORB, prometheus_histogram, [stage], "Block unvalidated absorb duration"},
          {?METRICS_BLOCK_UNVAL_HEIGHT, prometheus_gauge, [time], "Most recent unvalidated block height"} ]
    },
    txn_metrics => {
        [ [blockchain, txn, absorb],
          [blockchain, txn_mgr, submit],
          [blockchain, txn_mgr, reject],
          [blockchain, txn_mgr, accept],
          [blockchain, txn_mgr, process],
          [blockchain, txn_mgr, add_block] ],
        [ {?METRICS_TXN_ABSORB_DURATION, prometheus_histogram, [stage], "Txn absorb duration"},
          {?METRICS_TXN_SUBMIT_COUNT, prometheus_counter, [type], "Count of submitted transactions"},
          {?METRICS_TXN_REJECT_COUNT, prometheus_counter, [type], "Count of rejected transactions"},
          {?METRICS_TXN_REJECT_SPAN, prometheus_gauge, [type], "Block span of transactions on final rejection"},
          {?METRICS_TXN_ACCEPT_COUNT, prometheus_counter, [type], "Count of accepted transactions"},
          {?METRICS_TXN_ACCEPT_SPAN, prometheus_gauge, [type], "Block span of transactions on acceptance"},
          {?METRICS_TXN_PROCESS_DURATION, prometheus_histogram, [stage], "Transaction manager cache process duration"},
          {?METRICS_TXN_CACHE_SIZE, prometheus_gauge, [height], "Transaction manager buffer size"},
          {?METRICS_TXN_BLOCK_TIME, prometheus_gauge, [height], "Block time observed from the transaction mgr"},
          {?METRICS_TXN_BLOCK_AGE, prometheus_gauge, [height], "Block age observed from the transaction mgr"} ]
    },
    grpc_metrics => {
        [ [grpcbox, server, rpc_begin],
          [grpcbox, server, rpc_end] ],
        [ {?METRICS_GRPC_SESSIONS, prometheus_gauge, [method], "Grpc session count"},
          {?METRICS_GRPC_LATENCY, prometheus_histogram, [method, status], "Grpc session latency"} ]
    },
    state_channel_metrics => {
        [ [blockchain, state_channel, open],
          [blockchain, state_channel, close] ],
        [ {?METRICS_SC_COUNT, prometheus_gauge, [version, id], "Active state channel count"} ]
    },
    snapshot_metrics => {
        [ [blockchain, snapshot, generate],
          [blockchain, snapshot, load] ],
        [ {?METRICS_SNAP_GEN_SIZE, prometheus_gauge, [blocks, version], "Generated snapshot byte size"},
          {?METRICS_SNAP_GEN_DURATION, prometheus_gauge, [blocks, version], "Generated snapshot processing duration"},
          {?METRICS_SNAP_LOAD_SIZE, prometheus_gauge, [height, hash, version, source], "Loaded snapshot byte size"},
          {?METRICS_SNAP_LOAD_DURATION, prometheus_gauge, [height, hash, version, source], "Loaded snapshot processing duration"} ]
    }
}).
