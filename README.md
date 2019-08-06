# Miner

Miner performs all the various functions of a mining node on the Helium blockchain, including distributed key generation, block propogation and validation, the HoneybadgerBFT consensus protocol. 

Miner is designed to run on a Linux host, with a LongFi compatible multi-channel radio receiver. 

NOTE: In order to participate in Proof-of-Coverage challenges and transfer wireless data packets it is necessary to also install [Concentrate](https://github.com/helium/concentrate).

# Install

Welcome to Helium! 👋

## System Requirements

To build a low-cost Helium compatible Hotspot, we recommend using a [Raspberry Pi 3B+](https://www.raspberrypi.org) running the latest [Raspian Buster](https://www.raspberrypi.org/downloads/raspbian/) image with a [RAK2245 Pi Hat](https://store.rakwireless.com/products/rak2245-pi-hat) installed, and a recommended 64GB sdcard. In theory any Linux host and any SX1301-based concentrator board that interfaces to the host via SPI can be used, but are untested as of this writing.

This README will assume the Raspberry Pi + RAK2245 combination described above.

### Raspberry Pi specific setup

The default Raspian image has a small swapfile of 100MB, which on a Pi with 1GB or less of RAM is insufficient for building some of the dependencies, such as [RocksDB](http://rocksdb.org/). To increase the swap size, first stop the swap:

```sudo dphys-swapfile swapoff```

Edit the swapfile configuration as root `sudo nano /etc/dphys-swapfile` and change the `CONF_SWAPSIZE`:

```CONF_SWAPSIZE=1024```

Save the file, then start the swap again:

```sudo dphys-swapfile swapon```

Next, enable SPI and I2C by running `sudo raspi-config` and selecting `Interfacing Options`, and enabling I2C and SPI from within the menu system.

## Install from Source

First, you'll need [git](https://git-scm.com/). If you don't have it installed:

```sudo apt-get install git```

Clone the git repository:

```git clone https://github.com/helium/miner.git```

You will need to install the dependencies listed below in order to use the Miner.

### Install Erlang

Miner has been tested again [Erlang OTP 21.3](https://www.erlang.org/downloads/21.3).

To install OTP 21.3 in Raspian, we'll first acquire the Erlang package from [Erlang Solutions](https://www.erlang-solutions.com/resources/download.html) and then install the dependencies:

```
wget https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_21.3.3-1~raspbian~stretch_armhf.deb
sudo dpkg -i esl-erlang_21.3.3-1~raspbian~stretch_armhf.deb
sudo apt-get install -f
```

Install various other dependencies:

```sudo apt-get install libdbus-1-dev autoconf automake libtool flex libgmp-dev cmake libsodium-dev libssl-dev bison libsnappy-dev```

### Compile the Miner

Once the Miner has been cloned and Erlang installed, we can create a release using [rebar3](https://www.rebar3.org/). Rebar will handle all the Erlang dependencies and build the application. This will take a while:

```
cd miner
./rebar3 as prod release
```

Once this completes, you're ready to run the Miner.

## Usage

Congrats! You've installed the Miner 🚀 Now it's time to make some things happen.

### Starting Up

You can run the Miner in the background, or via an interactive console. 

To run in the background:

```_build/prod/rel/miner/bin/miner start```

To run via the interactive console:

```_build/prod/rel/miner/bin/miner console```

If you run in console mode, you'll need to open another terminal to execute any other commands.

### Checking the peer-to-peer network

The Helium blockchain uses an Erlang implementation of [libp2p](https://libp2p.io/). Because we expect Hotspot hardware to be installed in a wide variety of networking environments [erlang-libp2p](https://github.com/helium/erlang-libp2p) includes a number of additions to the core specification that provides support for NAT detection, proxying and relaying.

The first order of business once the Miner is running is to see if you're connected to any peers, whether your NAT type has been correctly identified, and that you have some listen addresses:

```_build/prod/rel/miner/bin/miner peer book -s```

You will see an output roughly like the following:

```
```
