#!/bin/bash

check_height() {
    nodes=$(seq 8)
    for node in ${nodes[@]}; do
        echo "miner$node, height: "$(./_build/dev\+miner$node/rel/miner$node/bin/miner$node info height)
    done
    echo ""
}

export -f check_height
while true; do check_height; sleep 1; done
