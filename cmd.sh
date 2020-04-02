#!/bin/sh

NODE=$1
shift

./_build/testdev\+miner${NODE}/rel/miner${NODE}/bin/miner${NODE} $@
