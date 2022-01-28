# add system user for file ownership and systemd user, if not exists
useradd --system helium || true

# add hotfix directory if it doesn't already exist
if [ ! -d /opt/miner/hotfix ]; then
    mkdir -p /opt/miner/hotfix
fi
