ARG BUILDER_IMAGE=erlang:23.3.4.6-alpine
ARG RUNNER_IMAGE=erlang:23.3.4.6-alpine
FROM ${BUILDER_IMAGE} as builder

ARG REBAR_BUILD_TARGET
ARG VERSION
ARG TAR_PATH=_build/$REBAR_BUILD_TARGET/rel/*/*.tar.gz

ARG EXTRA_BUILD_APK_PACKAGES

RUN apk add --no-cache --update \
    git tar build-base linux-headers autoconf automake libtool pkgconfig \
    dbus-dev bzip2 bison flex gmp-dev cmake lz4 libsodium-dev openssl-dev \
    sed wget curl tpm2-tss-dev\
    ${EXTRA_BUILD_APK_PACKAGES}

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

WORKDIR /usr/src/miner

ENV CC=gcc CXX=g++ CFLAGS="-U__sun__" \
    ERLANG_ROCKSDB_OPTS="-DWITH_BUNDLE_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    ERL_COMPILER_OPTIONS="[deterministic]" \
    PATH="/root/.cargo/bin:$PATH" \
    RUSTFLAGS="-C target-feature=-crt-static"

# Add our code
ADD . /usr/src/miner/

RUN ./rebar3 as ${REBAR_BUILD_TARGET} tar -n miner -v ${VERSION}

RUN mkdir -p /opt/docker/update
RUN tar -zxvf ${TAR_PATH} -C /opt/docker
RUN wget -O /opt/docker/update/genesis https://snapshots.helium.wtf/genesis.mainnet

FROM ${RUNNER_IMAGE} as runner

ARG EXTRA_RUNNER_APK_PACKAGES

RUN apk add --no-cache --update ncurses dbus gmp libsodium gcc tpm2-tss-esys tpm2-tss-fapi tpm2-tss-mu tpm2-tss-rc tpm2-tss-tcti-device\
                                ${EXTRA_RUNNER_APK_PACKAGES}

RUN ulimit -n 64000

WORKDIR /opt/miner

ENV COOKIE=miner \
    # Write files generated during startup to /tmp
    RELX_OUT_FILE_PATH=/tmp \
    # add miner to path, for easy interactions
    PATH=$PATH:/opt/miner/bin

COPY --from=builder /opt/docker /opt/miner

ENTRYPOINT ["/opt/miner/bin/miner"]
CMD ["foreground"]
