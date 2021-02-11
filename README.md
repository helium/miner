[![Build Status](https://badge.buildkite.com/a2ced4f1160fa02aa8b735e7edb80f8ef787a299963ff88942.svg?branch=master)](https://buildkite.com/helium/miner)

miner quickstart
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

Note that Miner for AMD64 requires AVX support on the processor due to the erasure library.


miner step-by-step
=====

This is a maybe up-to-date step by step on how to build Miner if you've never done it before. Results may vary depending on your host system.

This is for development purposes only and if you are interested in running a miner, please follow our guide [here](https://developer.helium.com/blockchain/run-your-own-miner).

## Installing Miner from Source

First, you'll need [git](https://git-scm.com/). If you don't have it installed:

```bash
sudo apt-get install git
```

Clone the git repository:

```bash
git clone https://github.com/helium/miner.git
```

### Install Erlang

Miner has been tested against Erlang OTP 22.3.1.

To install OTP 21.3.3 in Raspian, we'll first acquire the Erlang package from [Erlang Solutions](https://www.erlang-solutions.com/resources/download.html):

```bash
wget https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_22.1.6-1~raspbian~buster_armhf.deb
```

Now we'll install various other dependencies and then install Erlang itself. You'll see some errors after running `dpkg`, you can ignore them:

```bash
sudo apt-get install libdbus-1-dev autoconf automake libtool flex libgmp-dev cmake libsodium-dev libssl-dev bison libsnappy-dev libclang-dev doxygen make
sudo dpkg -i esl-erlang_22.1.6-1~raspbian~buster_armhf.deb
sudo apt-get install -f
```

### Compile the Miner

Now it's time to build the miner. This will take a while:

```bash
cd miner
make release
```

Note that Miner for AMD64 requires AVX support on the processor due to the erasure library.
