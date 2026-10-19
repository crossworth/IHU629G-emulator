# Build/analysis environment for the EX2 head unit emulator.
#
# arm64 Ubuntu 20.04 natively on Apple Silicon via Docker.
# 20.04 because the kernel is 4.14: GCC 9 is the newest compiler that builds
# it without -fno-common noise, and 20.04's default GCC IS 9.
#
# NOTE: every `tools/drun.sh` run is a FRESH container of this image.
# Anything a stage needs must be HERE (or in the ex2-kbuild volume).
# Adding apt-get calls to wrappers = invisible, slow, non-persistent.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc-9 \
        make bison flex bc libssl-dev libelf-dev \
        e2fsprogs dosfstools \
        device-tree-compiler u-boot-tools \
        cpio gzip xz-utils file \
        python3 python3-venv curl ca-certificates \
        fdisk xxd coreutils util-linux \
        git wget unzip \
        qemu-user-static \
        meson ninja-build pkg-config \
        libglib2.0-dev flex bison \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
