#!/bin/sh

if [ "$REGION" = 'EU868' ]; then
    cp /opt/miner/releases/0.1.0/eu.sys.config /opt/miner/releases/0.1.0/sys.config
elif [ "$REGION" = 'US915' ]; then
    cp /opt/miner/releases/0.1.0/us.sys.config /opt/miner/releases/0.1.0/sys.config
else
    cp /opt/miner/releases/0.1.0/default.sys.config /opt/miner/releases/0.1.0/sys.config
fi

/opt/miner/bin/miner foreground
