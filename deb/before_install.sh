# add system user for file ownership and systemd user, if not exists
useradd --system helium || true

# make the hotfix directory
if [ ! -d /opt/miner/hotfix ]; then
    mkdir -p /opt/miner/hotfix
fi
