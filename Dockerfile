ARG BUILDER_IMAGE=erlang:23.3.4.6-alpine
ARG RUNNER_IMAGE=alpine
FROM ${BUILDER_IMAGE} as builder

ARG REBAR_DIAGNOSTIC=0
ENV DIAGNOSTIC=${REBAR_DIAGNOSTIC}

ARG VERSION
ARG BUILD_NET
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

# # Add some basic pieces in
# ADD config /usr/src/miner/
# ADD rebar3 /usr/src/miner/
# ADD rebar.config /usr/src/miner/
# ADD rebar.lock /usr/src/miner/
# ADD rebar.config.script /usr/src/miner/
#
# # build the deps in a separate step
# RUN ./rebar3 get-deps as ${REBAR_BUILD_TARGET} && \
#     (cd _build/default/lib/rocksdb && ./../../../../rebar3 compile) && \
#     (cd _build/default/lib/ebus && ./../../../../rebar3 compile) && \
#     (cd _build/default/lib/longfi && ./../../../../rebar3 compile) && \
#     (cd _build/default/lib/blockchain && ./../../../../rebar3 compile) && \
#     (cd _build/default/lib/hbbft && ./../../../../rebar3 compile)


ADD . /usr/src/miner/

RUN ./rebar3 as ${REBAR_BUILD_TARGET} tar -n miner -v ${VERSION}

RUN mkdir -p /opt/docker/update
RUN tar -zxvf ${TAR_PATH} -C /opt/docker
RUN wget -O /opt/docker/update/genesis https://snapshots.helium.wtf/genesis.${BUILD_NET}

FROM ${RUNNER_IMAGE} as runner

ARG VERSION
ARG EXTRA_RUNNER_APK_PACKAGES

RUN apk add --no-cache --update ncurses dbus libsodium libgcc libstdc++ \
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
