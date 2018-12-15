#!/bin/bash

make clean && make

if [ -z "$1" ]
then
    echo "Will forge a blockchain from scratch"
    command="forge"
else
    echo "Will use provided $1 genesis file and incorporate the transactions"
    command="create"
    old_genesis_file=$1
fi

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
    echo $(./_build/dev/rel/miner-dev$1/bin/miner-dev$1 genesis create $2 $3)
}
export -f create_genesis_block

forge_genesis_block() {
    echo $(./_build/dev/rel/miner-dev$1/bin/miner-dev$1 genesis forge $2)
}
export -f forge_genesis_block

if [ "$command" == "create" ]
then
    parallel -k --tagstring miner-dev{} create_genesis_block ::: $nodes ::: $old_genesis_file ::: $(join_by , ${peer_addrs[@]})
elif [ "$command" == "forge" ]
then
    parallel -k --tagstring miner-dev{} forge_genesis_block ::: $nodes ::: $(join_by , ${peer_addrs[@]})
else
    exit 1
fi

# show which node is in the consensus group
non_consensus_node=0
for node in ${nodes[@]}; do
    if [[ $(./_build/dev/rel/miner-dev$node/bin/miner-dev$node info in_consensus) = *true* ]]; then
        echo "miner-dev$node, in_consensus: true"
    else
        echo "miner-dev$node, in_consensus: false"
        non_consensus_node=$node
        # load blockchain from dbfile on this node
        # blockchain_db_file=$(ls -d $PWD/$(find ./_build/dev/rel/miner-dev*/data -name "blockchain.db" | head -n 1))
        # echo "loading blockchain file $blockchain_db_file on miner-dev$node"
        # ./_build/dev/rel/miner-dev$node/bin/miner-dev$node genesis load $blockchain_db_file
    fi
done
echo "Node not in consensus: $non_consensus_node"

genesis_block=0
# get the genesis block from one of the consensus nodes
for node in ${nodes[@]}; do
    if [[ $(./_build/dev/rel/miner-dev$node/bin/miner-dev$node info in_consensus) = *true* ]]; then
        genesis_block=$(./_build/dev/rel/miner-dev$node/bin/miner-dev$node eval 'term_to_binary(element(2, blockchain:genesis_block(blockchain_worker:blockchain())))')
        break
    fi
done
echo "Genesis block: $genesis_block"

echo "Loading Genesis block on $non_consensus_node: $(./_build/dev/rel/miner-dev$non_consensus_node/bin/miner-dev$non_consensus_node genesis import $genesis_block)"
