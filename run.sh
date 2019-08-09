#!/bin/bash

#set -e

./all-cmd.sh stop

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

if [ -z $(which parallel) ]; then
    echo "missing GNU parallel, please install it"
    exit 1
fi

# default to 8 dev releases
nodes=$(seq 8)

# remove existing artifacts
rm -rf _build/dev+miner*

# build 8 dev releases
make devrel

start_dev_release() {
   echo $(./_build/dev\+miner$1/rel/miner$1/bin/miner$1 start)
   echo "Started: miner$1"
}
export -f start_dev_release
parallel -k --tagstring miner{} start_dev_release ::: $nodes

# peer addresses for node 1
addresses=($(./_build/dev\+miner1/rel/miner1/bin/miner1 peer listen --format=csv | tail -n +2))
echo $addresses

# connect node1 to every _other_ node
for node in ${nodes[@]}; do
    if (( $node != 1 )); then
        for address in ${addresses[@]}; do
            echo "## Node $node trying to connect to seed node 1 which has listen address: $address"
            ./_build/dev\+miner$node/rel/miner$node/bin/miner$node peer connect $address
        done
    fi
done

# get the peer addrs for each node
peer_addrs=()
for node in ${nodes[@]}; do
    peer_addrs+=($(./_build/dev\+miner$node/rel/miner$node/bin/miner$node peer addr))
done

# function to join array values
function join_by { local IFS="$1"; shift; echo "$*"; }

create_genesis_block() {
    echo $(./_build/dev\+miner$1/rel/miner$1/bin/miner$1 genesis create $2 $3 $4 $5)
}
export -f create_genesis_block

forge_genesis_block() {
    echo $(./_build/dev\+miner$1/rel/miner$1/bin/miner$1 genesis forge $2 $3 $4)
}
export -f forge_genesis_block

priv_key=$(./_build/dev\+miner1/rel/miner1/bin/miner1 genesis key)
echo $priv_key
proof=($(./_build/dev\+miner1/rel/miner1/bin/miner1 genesis proof $priv_key | grep -v ":"))
echo $proof
if [ "$command" == "create" ]
then
    parallel -k --tagstring miner{} create_genesis_block ::: $nodes ::: $old_genesis_file ::: ${proof[1]} ::: ${proof[0]} ::: $(join_by , ${peer_addrs[@]})
elif [ "$command" == "forge" ]
then
    parallel -k --tagstring miner{} forge_genesis_block ::: $nodes ::: ${proof[1]} ::: ${proof[0]} ::: $(join_by , ${peer_addrs[@]})
else
    exit 1
fi

# show which node is in the consensus group
non_consensus_node=""
for node in ${nodes[@]}; do
    if [[ $(./_build/dev\+miner$node/rel/miner$node/bin/miner$node info in_consensus) = *true* ]]; then
        echo "miner$node, in_consensus: true"
    else
        echo "miner$node, in_consensus: false"
        non_consensus_node+=" $node"
    fi
done
echo "Node not in consensus: $non_consensus_node"

exported_genesis_file="/tmp/genesis_$(date +%Y%m%d%H%M%S)"
# get the genesis block from one of the consensus nodes
LOOP=5
while [ $LOOP -ne 0 ]; do
    for node in ${nodes[@]}; do
        if [[ $(./_build/dev\+miner$node/rel/miner$node/bin/miner$node info in_consensus) = *true* ]]; then
            ./_build/dev\+miner$node/rel/miner$node/bin/miner$node genesis export $exported_genesis_file
            if [ $? -eq 0 ]; then
                LOOP=0
                break
            else
                LOOP=`expr $LOOP - 1`
            fi
        fi
    done
done

if [ -f $exported_genesis_file ]; then
    echo "Exported Genesis file: $exported_genesis_file"

    echo "Loading Genesis block on $non_consensus_node"
    for node in $non_consensus_node; do
        ./_build/dev\+miner$node/rel/miner$node/bin/miner$node genesis load $exported_genesis_file
    done
else
    echo "couldn't export genesis file"
    exit 1
fi
