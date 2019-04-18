#!/bin/sh

NODE=$1
shift

./_build/dev\+miner${NODE}/rel/miner${NODE}/bin/miner${NODE} $@
