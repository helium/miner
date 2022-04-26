# add miner to /usr/local/bin it appears in path
ln -s /opt/miner/bin/miner /usr/local/bin/miner

# if upgrading from old version with different file location, move miner data files to the new location
if [ -e /var/helium/miner/data/miner/swarm_key ] && [ ! -e /opt/miner/data/miner/swarm_key ]; then
    echo "Found existing swarm_key, moving data to /opt/miner/"
    mv /var/helium/miner/data /opt/miner/data
    chown -R helium:helium /opt/miner/data
elif [ -e /var/data/miner/miner/swarm_key ] && [ ! -e /opt/miner/data/miner/swarm_key ]; then
    echo "Found existing swarm_key, moving data to /opt/miner/"
    mv /var/data/miner /opt/miner/data
    chown -R helium:helium /opt/miner/data
else
    mkdir -p /opt/miner/data
    chown -R helium:helium /opt/miner/data
fi

mkdir -p /opt/miner/log
chown -R helium:helium /opt/miner/log
