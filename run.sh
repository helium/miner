#!/bin/bash

make clean && make

# default to 8 dev releases
nodes=$(seq 8)

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

# peer addresses for node 1
addresses=($(./_build/dev/rel/miner-dev1/bin/miner-dev1 peer listen --format=csv | tail -n +2))
echo $addresses

# connect node1 to every _other_ node
for node in ${nodes[@]}; do
    if (( $node != 1 )); then
        for address in ${addresses[@]}; do
            echo "## Node $node trying to connect to seed node 1 which has listen address: $address"
            ./_build/dev/rel/miner-dev$node/bin/miner-dev$node peer connect $address
        done
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
    if [[ $(./_build/dev/rel/miner-dev$node/bin/miner-dev$node info in_consensus) = *true* ]]; then
        echo "miner-dev$node, in_consensus: true"
    else
        echo "miner-dev$node, in_consensus: false"
        # load genesis block from file on this node
        genesis_file=$(ls -d $PWD/$(find ./_build/dev/rel/miner-dev*/data/blockchain -type f -name "genesis" | head -n 1))
        echo "loading genesis file $genesis_file on miner-dev$node"
        ./_build/dev/rel/miner-dev$node/bin/miner-dev$node genesis load $genesis_file
    fi
done
