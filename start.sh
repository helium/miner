#!/bin/bash

nodes=$(seq 8)

start_dev_release() {
   ./_build/testdev\+miner$1/rel/miner$1/bin/miner$1 daemon
}

export -f start_dev_release
parallel -k --tagstring miner{} start_dev_release ::: $nodes

sleep 5s
# peer addresses for node 1
addresses=()
# get the peer addrs for each node
peer_addrs=()

# function to join array values
function join_by { local IFS="$1"; shift; echo "$*"; }

# connect node1 to every _other_ node
for node in ${nodes[@]}; do
    peer_addrs+=($(./_build/testdev\+miner$node/rel/miner$node/bin/miner$node peer addr))
    
    if (( $node != 1 )); then
        for address in ${addresses[@]}; do
            echo "## Node $node trying to connect to seed node 1 which has listen address: $address"
            ./_build/testdev\+miner$node/rel/miner$node/bin/miner$node peer connect $address
        done
    else
        addresses+=($(./_build/testdev\+miner1/rel/miner1/bin/miner1 peer listen --format=csv | tail -n +2))
    fi

    sleep 1s
done

priv_key=$(./_build/testdev\+miner1/rel/miner1/bin/miner1 genesis key)
echo $priv_key
proof=($(./_build/testdev\+miner1/rel/miner1/bin/miner1 genesis proof $priv_key | grep -v ":"))
echo ${proof[@]}

forge_genesis_block() {
    ./_build/testdev\+miner$1/rel/miner$1/bin/miner$1 genesis forge $2 $3 $4
}
export -f forge_genesis_block

parallel -k --tagstring miner{} forge_genesis_block ::: $nodes ::: ${proof[1]} ::: ${proof[0]} ::: $(join_by , ${peer_addrs[@]})

# show which node is in the consensus group
exported_genesis_file="/tmp/genesis_$(date +%Y%m%d%H%M%S)"
non_consensus_node=""
for node in ${nodes[@]}; do
    if [[ $(./_build/testdev\+miner$node/rel/miner$node/bin/miner$node info in_consensus) = *true* ]]; then
        echo "miner$node, in_consensus: true"
        if [ ! -f $exported_genesis_file ]; then
            ./_build/testdev\+miner$node/rel/miner$node/bin/miner$node genesis export $exported_genesis_file
        fi
    else
        echo "miner$node, in_consensus: false"
        non_consensus_node+=" $node"
    fi
done
echo "Node not in consensus: $non_consensus_node"

if [ -f $exported_genesis_file ]; then
    echo "Exported Genesis file: $exported_genesis_file"

    echo "Loading Genesis block on $non_consensus_node"
    for node in $non_consensus_node; do
        ./_build/testdev\+miner$node/rel/miner$node/bin/miner$node genesis load $exported_genesis_file
    done

    # check everyone has the chain now
    for node in ${nodes[@]}; do
        ./_build/testdev\+miner$node/rel/miner$node/bin/miner$node info height > /dev/null
        if [[ $? -ne 0 ]]; then
            ./_build/testdev\+miner$node/rel/miner$node/bin/miner$node genesis load $exported_genesis_file
        fi
    done
else
    echo "couldn't export genesis file"
    exit 1
fi
