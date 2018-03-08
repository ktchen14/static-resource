FROM debian:stable-slim

RUN mkdir -p /opt/resource && \
    ln -sf /opt/static-resource /opt/resource/out && \
    ln -sf /opt/static-resource /opt/resource/in && \
    ln -sf /opt/static-resource /opt/resource/check

# GMP is required for Haskell
RUN apt-get update && apt-get install -y libgmp10 && \
    rm -rf /var/lib/apt/lists/*

COPY static-resource /opt/static-resource
