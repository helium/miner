[![Build Status](https://badge.buildkite.com/a2ced4f1160fa02aa8b735e7edb80f8ef787a299963ff88942.svg?branch=master)](https://buildkite.com/helium/miner)

# miner quickstart

Miner for helium blockchain

## Build

    $ make

## Typecheck

    $ make typecheck

## Test

    $ make test

# docker

Build a miner-test image locally:

```bash
docker build -t helium:miner-test -f .buildkite/scripts/Dockerfile-xxxNN .
```

Note that Miner for AMD64 requires AVX support on the processor due to the erasure library.

It is possible to build ARM64 images from an AMD64 machine. Install the following:

```bash
sudo apt-get install qemu binfmt-support qemu-user-static # Install the qemu packages
```

## Installing Miner from Source

### AMD64 (AMD/Intel)

You need a processor with `avx` extensions. You can check this exists by running the following- if it is empty, your processor doesn't support AVX.
```bash
grep avx /proc/cpuinfo
```
Next, install [git](https://git-scm.com/) and build dependencies.

```bash
apt install -y git erlang libdbus-1-dev autoconf automake libtool flex libgmp-dev cmake libsodium-dev libssl-dev bison libsnappy-dev libclang-dev doxygen vim build-essential cargo parallel
```

Clone the git repository:

```bash
git clone https://github.com/helium/miner.git
```

And build:
```bash
cd miner/
make release
```

### ARM (Raspbian) Install

Miner has been tested against Erlang OTP 22 and 23. Follow [this PR](https://github.com/helium/miner/pull/655) for progress on Erlang OTP 24 support. 

To install OTP 21.1.6 in Raspian, we'll first acquire the Erlang package from [Erlang Solutions](https://www.erlang-solutions.com/resources/download.html):

```bash
wget https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_22.1.6-1~raspbian~buster_armhf.deb
```

Now we'll install various other dependencies and then install Erlang itself. You'll see some errors after running `dpkg`, you can ignore them:

```bash
sudo apt-get install libdbus-1-dev autoconf automake libtool flex libgmp-dev cmake libsodium-dev libssl-dev bison libsnappy-dev libclang-dev doxygen make
sudo dpkg -i esl-erlang_22.1.6-1~raspbian~buster_armhf.deb
sudo apt-get install -f
```

Clone the git repository:

```bash
git clone https://github.com/helium/miner.git
```

Now it's time to build the miner. This will take a while:

```bash
cd miner
make release
```

