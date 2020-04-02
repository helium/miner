#!/bin/sh

parallel -k --tagstring miner{} _build/testdev\+miner{}/rel/miner{}/bin/miner{} $@ ::: 1 2 3 4 5 6 7 8
