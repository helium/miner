# [Choice] alpine,...
ARG VARIANT="alpine"
FROM erlang:${VARIANT} as deps-compiler

ENV DEBIAN_FRONTEND=noninteractive

# Setup rebar diagnostics
ARG REBAR_DIAGNOSTIC=0
ENV DIAGNOSTIC=${REBAR_DIAGNOSTIC}

ENV CC=gcc CXX=g++ CFLAGS="-U__sun__" \
    ERLANG_ROCKSDB_OPTS="-DWITH_BUNDLE_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    ERL_COMPILER_OPTIONS="[deterministic]" \
    PATH="/root/.cargo/bin:$PATH" \
    RUSTFLAGS="-C target-feature=-crt-static"

# Install dependencies to build
RUN apk add --no-cache --update \
    autoconf automake bison build-base bzip2 cmake curl \
    dbus-dev flex git gmp-dev libsodium-dev libtool linux-headers lz4 \
    openssl-dev pkgconfig protoc sed tar wget bash parallel

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
