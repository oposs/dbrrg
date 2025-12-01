# Makefile for dbrrg - SquashFS + OverlayFS + ZRAM + Dracut

PROJECT_NAME := dbrrg
VERSION := 2.0.0
BUILD_DATE := $(shell date -u +%Y-%m-%d)
BUILD_ID := $(shell date -u +%Y%m%d-%H%M%S)

CONTAINER_RUNTIME ?= podman

# Directories
ARTIFACT_DIR := artifacts
ROOTFS_DIR := $(ARTIFACT_DIR)/rootfs
IMAGE_DIR := $(ARTIFACT_DIR)/images

# Container images
UBUNTU_IMAGE := $(PROJECT_NAME)-ubuntu:$(VERSION)
IMAGE_BUILDER := $(PROJECT_NAME)-image-builder:$(VERSION)
IPXE_BUILDER := $(PROJECT_NAME)-ipxe:$(VERSION)

# Artifacts
KERNEL := $(ROOTFS_DIR)/vmlinuz
INITRD := $(ROOTFS_DIR)/initrd.img
SQUASHFS := $(ROOTFS_DIR)/ramroot.sqsh
USB_IMAGE := $(IMAGE_DIR)/$(PROJECT_NAME)-usb.img
USB_IMAGE_COMPRESSED := $(USB_IMAGE).zst
USB_CHECKSUM := $(USB_IMAGE_COMPRESSED).sha256
IPXE_PXE := $(ROOTFS_DIR)/ipxe.pxe
IPXE_KPXE := $(ROOTFS_DIR)/undionly.kpxe
IPXE_EFI := $(ROOTFS_DIR)/ipxe.efi

# Configuration
SQUASHFS_COMP ?= zstd
SQUASHFS_COMP_LEVEL ?= 3
EFI_PARTITION_SIZE ?= 2000

# QEMU settings
QEMU_MEMORY ?= 2G
QEMU_EXTRA_ARGS ?=

.PHONY: all clean rootfs image ipxe qemu-test qemu-test-console qemu-test-efi qemu-test-upgrade help

all: image
	@echo "✓ Build complete!"

help:
	@echo "dbrrg Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all (default)     - Build complete USB image"
	@echo "  rootfs            - Build kernel, initrd, squashfs"
	@echo "  ipxe              - Build iPXE network boot loaders"
	@echo "  image             - Build bootable USB image"
	@echo "  qemu-test         - Test boot image in QEMU (EFI)"
	@echo "  clean             - Remove artifacts"
	@echo "  help              - Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  SQUASHFS_COMP=zstd         - Compression algorithm"
	@echo "  SQUASHFS_COMP_LEVEL=3      - Compression level"
	@echo "  EFI_PARTITION_SIZE=2000    - EFI partition size (MB)"
	@echo "  QEMU_MEMORY=2G             - QEMU RAM allocation"
	@echo "  QCOW2_TEST_SIZE=4G         - Size for qemu-test"
	@echo "  QEMU_EXTRA_ARGS=\"\"          - Additional QEMU arguments"

$(ARTIFACT_DIR) $(ROOTFS_DIR) $(IMAGE_DIR):
	mkdir -p $@

# Find all overlay files (excluding editor backups)
OVERLAY_FILES := $(shell find overlay -type f ! -name '*~' 2>/dev/null)

# Remove stale stamp files if container images don't exist (checked at parse time)
$(if $(shell $(CONTAINER_RUNTIME) image exists $(UBUNTU_IMAGE) 2>/dev/null || echo missing),$(shell rm -f .ubuntu-container))
$(if $(shell $(CONTAINER_RUNTIME) image exists $(IMAGE_BUILDER) 2>/dev/null || echo missing),$(shell rm -f .image-builder-container))
$(if $(shell $(CONTAINER_RUNTIME) image exists $(IPXE_BUILDER) 2>/dev/null || echo missing),$(shell rm -f .ipxe-container))

.ubuntu-container: containers/ubuntu/Dockerfile $(OVERLAY_FILES) | $(ROOTFS_DIR)
	@echo "Building Ubuntu container..."
	$(CONTAINER_RUNTIME) build --pull --progress=plain \
		--build-arg VERSION=$(VERSION) \
		-t $(UBUNTU_IMAGE) \
		-f containers/ubuntu/Dockerfile \
		.
	@touch $@

$(KERNEL) $(INITRD) $(SQUASHFS): .ubuntu-container | $(ROOTFS_DIR)
	@echo "Exporting rootfs artifacts..."
	$(CONTAINER_RUNTIME) run --rm \
		-v $(PWD)/scripts:/scripts:ro \
		-v $(PWD)/artifacts:/artifacts \
		-e SQUASHFS_COMP=$(SQUASHFS_COMP) \
		-e SQUASHFS_COMP_LEVEL=$(SQUASHFS_COMP_LEVEL) \
		-e VERSION=$(VERSION) \
		-e BUILD_ID=$(BUILD_ID) \
		$(UBUNTU_IMAGE) \
		/scripts/export-rootfs.sh

rootfs: $(KERNEL) $(INITRD) $(SQUASHFS)

# iPXE build
.ipxe-container: containers/ipxe/Dockerfile | $(ROOTFS_DIR)
	@echo "Building iPXE container..."
	$(CONTAINER_RUNTIME) build --pull --progress=plain \
		-t $(IPXE_BUILDER) \
		-f containers/ipxe/Dockerfile \
		containers/ipxe
	@touch $@

$(IPXE_PXE) $(IPXE_KPXE) $(IPXE_EFI): .ipxe-container | $(ROOTFS_DIR)
	@echo "Exporting iPXE boot loaders..."
	$(CONTAINER_RUNTIME) run --rm \
		-v $(PWD)/artifacts/rootfs:/artifacts \
		$(IPXE_BUILDER)

ipxe: $(IPXE_PXE) $(IPXE_KPXE) $(IPXE_EFI)
	@echo "✓ iPXE boot loaders built"

.image-builder-container: containers/image-builder/Dockerfile | $(IMAGE_DIR)
	@echo "Building image builder container..."
	$(CONTAINER_RUNTIME) build --pull --progress=plain \
		-t $(IMAGE_BUILDER) \
		-f containers/image-builder/Dockerfile \
		containers/image-builder
	@touch $@

$(USB_IMAGE): rootfs .image-builder-container | $(IMAGE_DIR)
	@echo "Creating bootable USB image..."
	$(CONTAINER_RUNTIME) run --rm \
		-v $(PWD)/scripts:/scripts:ro \
		-v $(PWD)/artifacts:/artifacts \
		-v $(PWD)/configs:/configs:ro \
		-e EFI_PARTITION_SIZE=$(EFI_PARTITION_SIZE) \
		-e VERSION=$(VERSION) \
		-e BUILD_ID=$(BUILD_ID) \
		-e PROJECT_NAME=$(PROJECT_NAME) \
		$(IMAGE_BUILDER) \
		/scripts/make-bootable-image.sh

$(USB_IMAGE_COMPRESSED): $(USB_IMAGE)
	@echo "Compressing USB image..."
	zstd -f -3 -T0 $(USB_IMAGE) -o $(USB_IMAGE_COMPRESSED)
	@echo "✓ Compressed: $$(du -h $(USB_IMAGE_COMPRESSED) | cut -f1) (was $$(du -h $(USB_IMAGE) | cut -f1))"

$(USB_CHECKSUM): $(USB_IMAGE_COMPRESSED)
	@sha256sum $(USB_IMAGE_COMPRESSED) > $(USB_CHECKSUM)
	@echo "✓ Checksum created"

image: $(USB_IMAGE_COMPRESSED) $(USB_CHECKSUM)
	@echo ""
	@echo "To write to USB: zstd -d < $(USB_IMAGE_COMPRESSED) | dd of=/dev/sdX bs=1M status=progress conv=fsync"

# Test upgrade with qcow2 drives
QCOW2_BOOT_IMAGE := $(IMAGE_DIR)/$(PROJECT_NAME)-boot.qcow2
QCOW2_TARGET_IMAGE := $(IMAGE_DIR)/$(PROJECT_NAME)-target.qcow2
QCOW2_EMPTY_IMAGE := $(IMAGE_DIR)/$(PROJECT_NAME)-empty.qcow2
QCOW2_TEST_SIZE ?= 4G

# Always rebuild qcow2 from current USB image (force recreate)
.PHONY: $(QCOW2_BOOT_IMAGE) $(QCOW2_TARGET_IMAGE) $(QCOW2_EMPTY_IMAGE)

$(QCOW2_BOOT_IMAGE): $(USB_IMAGE)
	@echo "Creating boot drive ($(QCOW2_TEST_SIZE) sparse qcow2)..."
	rm -f $(QCOW2_BOOT_IMAGE)
	qemu-img convert -f raw -O qcow2 $(USB_IMAGE) $(QCOW2_BOOT_IMAGE)
	qemu-img resize $(QCOW2_BOOT_IMAGE) $(QCOW2_TEST_SIZE)

$(QCOW2_TARGET_IMAGE): $(USB_IMAGE)
	@echo "Creating target drive ($(QCOW2_TEST_SIZE) sparse qcow2)..."
	rm -f $(QCOW2_TARGET_IMAGE)
	qemu-img convert -f raw -O qcow2 $(USB_IMAGE) $(QCOW2_TARGET_IMAGE)
	qemu-img resize $(QCOW2_TARGET_IMAGE) $(QCOW2_TEST_SIZE)

$(QCOW2_EMPTY_IMAGE):
	@echo "Creating empty drive ($(QCOW2_TEST_SIZE) sparse qcow2)..."
	rm -f $(QCOW2_EMPTY_IMAGE)
	qemu-img create -f qcow2 $(QCOW2_EMPTY_IMAGE) $(QCOW2_TEST_SIZE)

qemu-test: $(QCOW2_BOOT_IMAGE) $(QCOW2_TARGET_IMAGE) $(QCOW2_EMPTY_IMAGE)
	@echo "Starting QEMU with 3 drives for upgrade testing..."
	@echo "  Boot drive:   $(QCOW2_BOOT_IMAGE) (vda) - current dbrrg"
	@echo "  Target drive: $(QCOW2_TARGET_IMAGE) (vdb) - dbrrg for A/B test"
	@echo "  Empty drive:  $(QCOW2_EMPTY_IMAGE) (vdc) - fresh install test"
	@echo ""
	@echo "Run 'upgrade-image' to test upgrade workflow"
	@echo "Press Ctrl+A then X to exit QEMU"
	@echo ""
	qemu-system-x86_64 \
   	        -machine type=q35,accel=kvm \
   	        -cpu host,migratable=off \
   	        -object rng-random,filename=/dev/urandom,id=rng0 \
   	        -device virtio-rng-pci,rng=rng0 \
		-m $(QEMU_MEMORY) \
		-bios /usr/share/ovmf/OVMF.fd \
		-boot c \
		-display gtk \
		-device virtio-vga,xres=1920,yres=1080 \
		-net nic,model=virtio \
		-net user \
		-enable-kvm \
		-drive file=$(QCOW2_BOOT_IMAGE),format=qcow2,if=virtio \
		-drive file=$(QCOW2_TARGET_IMAGE),format=qcow2,if=virtio \
		-drive file=$(QCOW2_EMPTY_IMAGE),format=qcow2,if=virtio \
		-serial mon:stdio \
		$(QEMU_EXTRA_ARGS)

clean:
	rm -rf $(ARTIFACT_DIR)/*
	rm -f .ubuntu-container .image-builder-container .ipxe-container
	@echo "✓ Cleaned artifacts"

