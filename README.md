[![Build Status](https://badge.buildkite.com/a2ced4f1160fa02aa8b735e7edb80f8ef787a299963ff88942.svg?branch=master)](https://buildkite.com/helium/miner)

miner
=====

Miner for helium blockchain

Build
-----

    $ make

Typecheck
-----

    $ make typecheck

Test
-----

    $ make test

docker
=====

Build a miner-test image locally:

```
docker build -t helium:miner-test -f .buildkite/scripts/Dockerfile-xxxNN .
```
