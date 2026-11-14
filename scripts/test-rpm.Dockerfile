FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash coreutils rpm yq \
    && rm -rf /var/lib/apt/lists/*
