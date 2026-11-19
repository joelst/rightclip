FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        g++ \
        make \
        gcc-mingw-w64-x86-64 \
        g++-mingw-w64-x86-64 \
        nasm \
        cmake \
        ninja-build \
        pkg-config \
        python3 \
        ca-certificates \
        curl \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY sources.json build.sh /src/
RUN chmod +x /src/build.sh

ENTRYPOINT ["/src/build.sh"]
