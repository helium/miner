#!/bin/sh

NODE=$1
shift

./_build/dev/rel/miner-dev${NODE}/bin/miner-dev${NODE} $@
