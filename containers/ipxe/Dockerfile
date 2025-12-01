# iPXE Network Boot Builder
# Builds iPXE PXE and EFI boot loaders from source

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    liblzma-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone iPXE source
RUN git clone --depth 1 https://github.com/ipxe/ipxe.git /ipxe

# Build iPXE for BIOS and EFI
WORKDIR /ipxe/src
RUN make -j$(nproc) \
    bin-x86_64-pcbios/ipxe.pxe \
    bin-x86_64-pcbios/undionly.kpxe \
    bin-x86_64-efi/ipxe.efi

# Default command exports the built files
CMD ["sh", "-c", "cp /ipxe/src/bin-x86_64-pcbios/ipxe.pxe /ipxe/src/bin-x86_64-pcbios/undionly.kpxe /ipxe/src/bin-x86_64-efi/ipxe.efi /artifacts/"]
