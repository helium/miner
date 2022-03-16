ARG BUILDER_IMAGE=erlang:24-slim
ARG RUNNER_IMAGE=debian:bullseye-slim
FROM ${BUILDER_IMAGE} as deps-compiler

ARG REBAR_DIAGNOSTIC=0
ENV DIAGNOSTIC=${REBAR_DIAGNOSTIC}

ARG REBAR_BUILD_TARGET
ARG TAR_PATH=_build/$REBAR_BUILD_TARGET/rel/*/*.tar.gz
ARG EXTRA_BUILD_APT_PACKAGES

RUN apt update \
    && apt install -y --no-install-recommends \
       autoconf \
       automake \
       bison \
       build-essential \
       bzip2 \
       ca-certificates \
       cmake \
       curl \
       flex \
       git \
       libdbus-1-dev \
       libgmp-dev \ 
       libprotobuf-dev \
       libsodium-dev \
       libssl-dev \
       libtool \
       lz4 \
       libprotobuf-dev \
       wget \
       ${EXTRA_BUILD_APT_PACKAGES} 

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

WORKDIR /usr/src/miner

ENV CC=gcc CXX=g++ CFLAGS="-O2" CXXFLAGS="-O2" \
    ERLANG_ROCKSDB_OPTS="-DWITH_BUNDLE_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    ERL_COMPILER_OPTIONS="[deterministic]" \
    PATH="/root/.cargo/bin:$PATH" 

# Add and compile the dependencies to cache
COPY ./rebar* ./Makefile ./
COPY ./config/grpc_client_gen_local.config ./config/

RUN ./rebar3 compile

FROM deps-compiler as builder

ARG VERSION
ARG REBAR_DIAGNOSTIC=0

# default to building for mainnet
ARG BUILD_NET=mainnet
ENV DIAGNOSTIC=${REBAR_DIAGNOSTIC}

ARG REBAR_BUILD_TARGET
ARG TAR_PATH=_build/$REBAR_BUILD_TARGET/rel/*/*.tar.gz

# Now add our code
COPY . .

RUN ./rebar3 as ${REBAR_BUILD_TARGET} tar -n miner -v ${VERSION}

RUN mkdir -p /opt/docker/update
RUN tar -zxvf ${TAR_PATH} -C /opt/docker
RUN wget -O /opt/docker/update/genesis https://snapshots.helium.wtf/genesis.${BUILD_NET}

FROM ${RUNNER_IMAGE} as runner

ARG VERSION
ARG EXTRA_RUNNER_APT_PACKAGES

RUN apt update \
    && apt install -y \
       dbus \
       iproute2 \
       libncurses6 \
       libsodium23 \
       libstdc++6 \
       ${EXTRA_RUNNER_APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists \
    && ln -sf /opt/miner/releases/${VERSION} /config

WORKDIR /opt/miner

ENV COOKIE=miner \
    # Write files generated during startup to /tmp
    RELX_OUT_FILE_PATH=/tmp \
    # add miner to path, for easy interactions
    PATH=$PATH:/opt/miner/bin

COPY --from=builder /opt/docker /opt/miner

VOLUME ["/opt/miner/hotfix", "/var/data"]

ENTRYPOINT ["/opt/miner/bin/miner"]
CMD ["foreground"]
