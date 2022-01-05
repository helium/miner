ARG BUILDER_IMAGE=erlang:24-alpine
ARG RUNNER_IMAGE=alpine
FROM ${BUILDER_IMAGE} as deps-compiler

ARG REBAR_DIAGNOSTIC=0
ENV DIAGNOSTIC=${REBAR_DIAGNOSTIC}

ARG REBAR_BUILD_TARGET
ARG TAR_PATH=_build/$REBAR_BUILD_TARGET/rel/*/*.tar.gz
ARG EXTRA_BUILD_APK_PACKAGES

RUN apk add --no-cache --update \
    git tar build-base linux-headers autoconf automake libtool pkgconfig \
    dbus-dev bzip2 bison flex gmp-dev cmake lz4 libsodium-dev openssl-dev \
    sed wget curl \
    ${EXTRA_BUILD_APK_PACKAGES}

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

WORKDIR /usr/src/miner

ENV CC=gcc CXX=g++ CFLAGS="-U__sun__" \
    ERLANG_ROCKSDB_OPTS="-DWITH_BUNDLE_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    ERL_COMPILER_OPTIONS="[deterministic]" \
    PATH="/root/.cargo/bin:$PATH" \
    RUSTFLAGS="-C target-feature=-crt-static"

# Add and compile the dependencies to cache
COPY ./rebar* ./

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
ARG EXTRA_RUNNER_APK_PACKAGES

RUN apk add --no-cache --update ncurses dbus libsodium libstdc++ \
                                ${EXTRA_RUNNER_APK_PACKAGES}

RUN ulimit -n 64000

WORKDIR /opt/miner

ENV COOKIE=miner \
    # Write files generated during startup to /tmp
    RELX_OUT_FILE_PATH=/tmp \
    # add miner to path, for easy interactions
    PATH=$PATH:/opt/miner/bin

COPY --from=builder /opt/docker /opt/miner

RUN ln -sf /opt/miner/releases/${VERSION} /config

ENTRYPOINT ["/opt/miner/bin/miner"]
CMD ["foreground"]
