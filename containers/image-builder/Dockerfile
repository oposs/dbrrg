FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    syslinux \
    syslinux-efi \
    mtools \
    dosfstools \
    gdisk \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
