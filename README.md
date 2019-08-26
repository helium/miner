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

### Editing the configuration

The `sys.config` will need to be edited to match your configuration. Assuming you aren't using Helium Hotspot hardware you'll need to change the following lines of the configuration file:

`vim _build/prod/rel/miner/releases/0.1.0/sys.config`

Change the following settings:

`{key, undefined}`
`{use_ebus, false}`

You should also edit `log_root`, `base_dir` and `update_dir` to be appropriate for whatever you prefer on your system.

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
+--------------------------------------------------------+------------------------------+------------+-----------+---------+------------+
|                        address                         |             name             |listen_addrs|connections|   nat   |last_updated|
+--------------------------------------------------------+------------------------------+------------+-----------+---------+------------+
|/p2p/11dwT67atkEe1Ru6xhDqPhSXKXmNhWf3ZHxX5S4SXhcdmhw3Y1t|{ok,"genuine-steel-crocodile"}|     2      |    13     |symmetric|   3.148s   |
+--------------------------------------------------------+------------------------------+------------+-----------+---------+------------+

+----------------------------------------------------------------------------------------------------------------------------+
|                                                 listen_addrs (prioritized)                                                 |
+----------------------------------------------------------------------------------------------------------------------------+
|/p2p/11apmNb8phR7WXMx8Pm65ycjVY16rjWw3PvhSeMFkviWAUu9KRD/p2p-circuit/p2p/11dwT67atkEe1Ru6xhDqPhSXKXmNhWf3ZHxX5S4SXhcdmhw3Y1t|
|                                                 /ip4/192.168.3.6/tcp/36397                                                 |
+----------------------------------------------------------------------------------------------------------------------------+

+--------------------------+-----------------------------+---------------------------------------------------------+------------------------------+
|          local           |           remote            |                           p2p                           |             name             |
+--------------------------+-----------------------------+---------------------------------------------------------+------------------------------+
|/ip4/192.168.3.6/tcp/36397|/ip4/104.248.122.141/tcp/2154|/p2p/112GZJvJ4yUc7wubREyBHZ4BVYkWxQdY849LC2GGmwAnv73i5Ufy|{ok,"atomic-parchment-snail"} |
|/ip4/192.168.3.6/tcp/36397| /ip4/73.15.36.201/tcp/13984 |/p2p/112MtP4Um2UXo8FtDHeme1U5A91M6Jj3TZ3i2XTJ9vNUMawqoPVW|   {ok,"fancy-glossy-rat"}    |
|/ip4/192.168.3.6/tcp/36397| /ip4/24.5.52.135/tcp/41103  |/p2p/11AUHAqBatgrs2v6j3j75UQ73NyEYZoH41CdJ56P1SzeqqYjZ4o |  {ok,"skinny-fuchsia-mink"}  |
|/ip4/192.168.3.6/tcp/46059| /ip4/34.222.64.221/tcp/2154 |/p2p/11LBadhdCmwHFnTzCTucn6aSPieDajw4ri3kpgAoikgnEA62Dc6 | {ok,"skinny-lilac-mustang"}  |
|/ip4/192.168.3.6/tcp/33547| /ip4/34.208.255.251/tcp/443 |/p2p/11VjFZM14JK3oecVuVfYSgAM9oZy1J98kQW8AZMQgLZC4p4noih |   {ok,"fast-pebble-snake"}   |
|/ip4/192.168.3.6/tcp/36397|  /ip4/45.33.47.34/tcp/443   |/p2p/11apmNb8phR7WXMx8Pm65ycjVY16rjWw3PvhSeMFkviWAUu9KRD |{ok,"radiant-cobalt-tadpole"} |
|/ip4/192.168.3.6/tcp/36397| /ip4/67.48.33.86/tcp/49909  |/p2p/11ckxdQsReXpqwCrbbREZj6urEuNEGf2Zk5d4UnsuPMsJDSihwy |{ok,"orbiting-cream-starfish"}|
|/ip4/192.168.3.6/tcp/36397|/ip4/73.241.19.171/tcp/45312 |/p2p/11dj5k2dwSUE7fqFnwAHK9stLd3St9MJiJuaRnvvRgJjbRMZgKJ |   {ok,"micro-tiger-tuna"}    |
|/ip4/192.168.3.6/tcp/36397| /ip4/178.128.88.28/tcp/443  |/p2p/11sRJ9L6nenuBDK8RNvswXThvu6aYyPNA7Rsq6bV1dWG1veyYaS | {ok,"curved-rouge-hedgehog"} |
|/ip4/192.168.3.6/tcp/36397|/ip4/54.152.161.170/tcp/2154 |/p2p/11tZZW54iY4WF481DmrMdVe2QVi2K9m6dXEZps6GvPTqyWZp5V3 |{ok,"harsh-honeysuckle-shark"}|
|/ip4/192.168.3.6/tcp/36397|/ip4/70.113.51.183/tcp/61383 |/p2p/11vsUeTb8g4KcELPctghGLSDWhUDGAEAkiAhERU3euC69HSNvca |  {ok,"long-rosewood-boar"}   |
|/ip4/192.168.3.6/tcp/36397|/ip4/104.248.206.159/tcp/443 |/p2p/11wDt78AktL5ZMmV8ePxZWAu8wyVRLbArFeqhCVExzyd3HP6hQa |   {ok,"fluffy-sand-yeti"}    |
|/ip4/192.168.3.6/tcp/36397|/ip4/192.168.2.134/tcp/62146 |/p2p/11xxCzYzQAxhfazMVa6vi7QBD4ct85baw7FLG9KPmERVttXBKhQ |{ok,"beautiful-coffee-oyster"}|
+--------------------------+-----------------------------+---------------------------------------------------------+------------------------------+
```

As long as you have an address listed in `listen_addrs` and some peers in the table at the bottom, you're connected to the p2p network and good to go.

### Loading the Genesis block

First, you need a genesis block from either the main network, or the Pescadero testnet. Get them here: [mainnet](NEED A URL HERE) or [pescadero](NEED A URL HERE).

Once you've downloaded it, you'll need to use the CLI to load the genesis block in to your local miner:

```_build/prod/rel/miner/bin/miner genesis load <path_to_genesis>```

After the genesis block has been loaded, you should be able to check your block height and see at least the genesis block:

```_build/prod/rel/miner/bin/miner info height```

The first number is the election epoch, and the second number is the block height of your miner.

## Adding to the Blockchain

In order to participate in mining and earning Helium tokens (HLM), the Gateway needs to be added to the blockchain. There are two steps required in order to do this, as both the `owner` and the `gateway` itself must sign a transaction.

### Creating the sign_gateway transaction

The `owner` is the address that receives mining rewards, and can make changes to the location of the gateway. In order to create the `sign_gateway` transaction, which has the owner sign the first half of the transaction, either a separate `miner` or `blockchain-api` instance needs to be running.

If you have created an address using the Helium mobile app the private key can be imported by running:

```NO CLI OR TECHNOLOGY EXISTS FOR THIS PART```

You can check what address your instance is running:

```_build/prod/rel/miner/bin/miner peer addr```

Once you've got the correct owner CLI set up, it's time to craft the `sign_gateway` transaction, which can be done as follows:

```_build/prod/rel/miner/bin/miner ledger sign_gateway -g <gateway_address> -s <stake> -f <fee>```

Replacing `gateway_address` with the address of the miner running on the Pi, `stake` with the appropriate staking fee, and `fee` with the transaction fee.

The output, a Base64 partially signed blockchain transaction, will be something similar to the following:

```
CpABCiEAisT0F3EJUKad4lhHbf1EWguG1C1T1Kja+nzrvZGiUSYSIQAu+yjG/8AgTVj7rNJUb6Tj2M20Qgn027dQJNBDZdYeixpGMEQCIEgLTfKe1c1jLzxRXNF+textVZJpt7PKZ29k3rfbZEo5AiA99UEPru7ppnjst0KYuj/0Mqx3ml9wLR2auxrMW04ISDA
ok
```

Copy and paste the Base64 string (the line before `ok`) into the Helium mobile app during the add hotspot process - you'll see an `Advanced` link that will allow you to paste this Base64 transaction into the app. After you've done that, the mobile app will re-sign the transaction via that owners address and submit it to the blockchain.

