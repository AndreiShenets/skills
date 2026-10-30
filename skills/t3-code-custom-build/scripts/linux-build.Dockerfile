FROM rust:bookworm@sha256:665b6e0a9290a7298236c08c6e4f1e754e3f0d9b70421c434daa3dfba888d63e

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 pkg-config ca-certificates util-linux patchelf \
    && rm -rf /var/lib/apt/lists/*
