#!/bin/bash
set -x

# default to 8 dev releases
nodes=$(seq 7)

# remove existing artifacts
rm -rf _build/dev

# build 8 dev releases
make devrel

start_dev_release() {
   echo $(./_build/dev/rel/miner-dev$1/bin/miner-dev$1 start)
   echo "Started: miner-dev$1"
}
export -f start_dev_release
parallel -k --tagstring miner-dev{} start_dev_release ::: $nodes

# peer addresses
addresses=()
for node in ${nodes[@]}; do
    addresses+=($(./_build/dev/rel/miner-dev$node/bin/miner-dev$node peer listen --format=csv | sed -n 2p))
done

# connect node1 to every _other_ node
for node in ${nodes[@]}; do
    if (( $node != 1 )); then
        echo "## Node $node trying to connect to seed node 1 which has listen address: ${addresses[0]} ##"
        ./_build/dev/rel/miner-dev$node/bin/miner-dev$node peer connect ${addresses[0]}
    fi
done

# get the peer addrs for each node
peer_addrs=()
for node in ${nodes[@]}; do
    peer_addrs+=($(./_build/dev/rel/miner-dev$node/bin/miner-dev$node peer addr))
done

# function to join array values
function join_by { local IFS="$1"; shift; echo "$*"; }

create_genesis_block() {
    echo $(./_build/dev/rel/miner-dev$1/bin/miner-dev$1 genesis create $2)
}
export -f create_genesis_block
parallel -k --tagstring miner-dev{} create_genesis_block ::: $nodes ::: $(join_by , ${peer_addrs[@]})

# show which node is in the consensus group
for node in ${nodes[@]}; do
    echo "miner-dev$node in_consensus: $(./_build/dev/rel/miner-dev$node/bin/miner-dev$node status in_consensus)"
done
