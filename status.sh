#!/bin/bash

check_height() {
    nodes=$(seq 8)
    for node in ${nodes[@]}; do
        echo "miner-dev$node, height: "$(./_build/dev/rel/miner-dev$node/bin/miner-dev$node info height)
    done
    echo ""
}

export -f check_height
while true; do check_height; sleep 1; done
