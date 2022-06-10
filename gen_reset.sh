#!/bin/bash
#set -e
# script containing helper functions as part of resetting a chain
# whilst keeping the existing ledger data
# WARNING: should only be used locally or on testnet

# expected flow:
# 1. select a group of nodes which will be used to form part of the initial dkg
# 2. on one of the group nodes, export the ledger data using 'export_ledger' cmd
#    the outputted file will contain gen txns for all existing ledger accounts, gateways, validators, oracle price & chainvars
#    !!!!!NOTE the master key outputted from step 2.  Retain a copy of this and make available where necessary !!!!
# 3. scp the file containing the exported ledger data from step 2 to all nodes in the group
# 4. run 'clean_data_dir' cmd on each node in the group.
#    !!!!NOTE: DESTRUCTIVE OPERATION!!!!
#    this will delete the existing chain, ledger & state channel DBs from disk and bounce the node
# 5. run 'connect_nodes' cmd on each node in the group ( ensures the group is fully connected )
# 6. run 'do_dkg' cmd on each node in the group, await for the dkg to complete
#    this will run an initial_dkg using the txns exported from step 2
#
# when the dkg completes, the genesis block can then be exported
# from one of the group nodes which formed part of the dkg
# ( using the regular miner genesis export cli ).
# load the genesis block onto the remaining group nodes which did not form part of the dkg
# distribute the genesis block freely & widely


export_ledger() {
  echo "exporting ledger..."
  # expected cli params
  miner_path=$1          # path to miner executable
  txn_path=$2            # path to write txn list file to
  # generate and output a new master key
  master_key=$($miner_path genesis key)
  # export the ledger data to a file containing txns for
  # accounts, gateways, validators & chainvars
  # master key is required to generate proof for the var txn
  echo $($miner_path genesis export_ledger $master_key $txn_path)
  echo "new master key: $master_key"
  echo "done"
}

clean_data_dir() {
  echo "deleting data..."
  # expected cli params
  miner_path=$1          # path to miner executable
  data_path=$2           # path to miner data dir
  # stop the miner and delete the necessary from the data directory
  echo $($miner_path stop)
  rm -rf $data_path/blockchain.db
  rm -rf $data_path/ledger.db
  rm -rf $data_path/state_channels.db
  echo $($miner_path daemon)
  echo "done"
}

connect_nodes() {
  echo "connecting nodes..."
  # expected cli params
  miner_path=$1          # path to miner executable
  addrs=$2               # comma separated string containing the p2p addrs of nodes to use in the initial dkg
  # connect the specified node to every _other_ node
  IFS=', ' read -r -a addresses <<< "$addrs"
  for addr in ${addresses[@]}; do
    $miner_path peer connect $addr
  done
  echo "done"
}

do_dkg(){
  echo "running dkg..."
  # expected cli params
  miner_path=$1          # path to miner executable
  txn_path=$2            # path to exported file containing the ledger txns
  addrs=$3               # comma separated string containing the p2p addrs of nodes to use in the initial dkg
  # run the initial dkg with the exported txns and the specified addresses
  # after the dkg completes the genesis block can then be exported
  # and distributed as necessary
  if (( $# < 5 ))
  then
    echo $($miner_path genesis recreate_ledger $txn_path $addrs)
  else
    # optional cli params
    n=$4
    curve=$5
    echo $($miner_path genesis recreate_ledger $txn_path $addrs $n $curve)
  fi
  echo "done"
}

cmd=$1;
case $cmd in
    export_ledger)
      "$@"; exit;;
    clean_data_dir)
      "$@"; exit;;
    connect_nodes)
      "$@"; exit;;
    do_dkg)
      "$@"; exit;;
esac

