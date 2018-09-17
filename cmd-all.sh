#!/bin/sh

parallel -k --tagstring miner-dev{} _build/dev/rel/miner-dev{}/bin/miner-dev{} $@ ::: 1 2 3 4 5 6 7
