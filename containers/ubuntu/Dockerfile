# Local labwc rebuild.
#
# Ubuntu's labwc 0.9.3 clamps fullscreen windows to a single output and does
# not implement zwp_xwayland_keyboard_grab_manager_v1. Both are patched here;
# see docs/superpowers/specs/2026-07-27-labwc-multimonitor-fullscreen-design.md.
#
# Patches live in containers/ubuntu/patches/ and are appended to the source
# package's quilt series in filename order. dpkg-buildpackage applies them, so
# a patch that no longer applies fails the build loudly instead of being
# silently skipped.
FROM ubuntu:26.04 AS labwc-build
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBEMAIL=dbrrg@localhost DEBFULLNAME=dbrrg

RUN sed -i 's/^Types: deb$/Types: deb deb-src/' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get install -yq --no-install-recommends \
        build-essential devscripts dpkg-dev quilt ca-certificates && \
    apt-get build-dep -yq labwc

WORKDIR /build
RUN apt-get source labwc

COPY containers/ubuntu/patches/ /patches/
RUN set -eu; \
    cd /build/labwc-*/; \
    for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        cp "$p" debian/patches/; \
        basename "$p" >> debian/patches/series; \
    done; \
    dch --local +dbrrg --distribution unstable "dbrrg local patches"; \
    dpkg-buildpackage -b -uc -us; \
    mkdir -p /out; \
    cp /build/labwc_*.deb /out/

FROM ubuntu:26.04
ARG DEBIAN_FRONTEND=noninteractive

# Update and install base packages in single layer to avoid stale cache.
#
# xcursor-themes ships Xcursor pointer theme files (whiteglass, redglass,
# handhelds) in this image. It used to arrive transitively via lxterminal
# (GTK) / xorg; both are gone now. Installing the package alone is not
# enough to get a visible pointer, though: it registers its themes with
# update-alternatives at priority 20, below x11-common's core.theme at
# priority 30, so the x-cursor-theme alternative still resolves to
# core.theme - which inherits from "core", the X server's built-in cursor
# font, meaningless to a Wayland compositor. XCURSOR_THEME in
# overlay/etc/dbrrg/labwc/environment is what actually selects
# xcursor-themes' whiteglass theme; both the package and that setting are
# required.
RUN apt-get update && apt-get upgrade -y && apt-get install -yq \
    --no-install-recommends --no-install-suggests \
    systemd-sysv \
    systemd-resolved \
    vim \
    wireguard \
    resolvconf-admin \
    openssh-server \
    sudo \
    curl \
    ca-certificates \
    iproute2 \
    iw \
    wpasupplicant \
    netplan.io \
    less \
    chrony \
    tzdata \
    joe \
    net-tools \
    pciutils \
    iputils-ping \
    locales \
    rsync \
    unzip \
    bluetooth \
    xwayland \
    foot \
    foot-terminfo \
    kanshi \
    wlr-randr \
    xfonts-base \
    fonts-dejavu-core \
    xcursor-themes \
    dialog \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-audio \
    wireplumber \
    libspa-0.2-bluetooth \
    pulseaudio-utils \
    alsa-utils \
    plymouth \
    plymouth-themes \
    plymouth-theme-spinner \
    intel-microcode \
    linux-image-generic \
    linux-modules-iwlwifi-generic \
    linux-firmware-minimal \
    linux-firmware-intel-graphics \
    linux-firmware-intel-wireless \
    linux-firmware-realtek \
    firmware-sof-signed \
    dracut \
    dracut-network \
    isc-dhcp-client \
    squashfs-tools \
    zstd \
    wget \
    dosfstools \
    parted \
    fdisk \
    gdisk \
    python3 \
    vainfo \
    intel-media-va-driver \
    i965-va-driver

# Set ping setuid
RUN chmod u+s /usr/bin/ping

# Install ThinLinc
RUN wget https://www.cendio.com/downloads/clients/thinlinc-client_4.20.0-4284_amd64.deb && \
    apt install -y ./thinlinc-client_4.20.0-*_amd64.deb && \
    rm -f thinlinc-client_*.deb

# Install locally built packages staged by the Makefile into vendor/
COPY vendor/oxulnk-desktop.deb /tmp/oxulnk-desktop.deb
RUN apt-get install -yq --no-install-recommends /tmp/oxulnk-desktop.deb && \
    rm -f /tmp/oxulnk-desktop.deb

# labwc comes from the local rebuild above, not the archive. apt resolves its
# dependencies from the .deb's own control fields. 0.9.3-1+dbrrg1 sorts above
# 0.9.3-1, so a later apt-get upgrade will not replace it.
COPY --from=labwc-build /out/ /tmp/labwc-deb/
RUN apt-get install -yq --no-install-recommends /tmp/labwc-deb/labwc_*.deb && \
    rm -rf /tmp/labwc-deb

# Remove root password
RUN passwd -d root

# Create user with simple password for console login
RUN adduser --disabled-password --gecos "ThinUser" tluser && \
    echo "tluser:tluser" | chpasswd && \
    adduser tluser sudo && \
    echo "tluser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    adduser tluser audio

# Apply overlay
ADD overlay/ /__overlay
RUN tar cf - --exclude="*~" -C /__overlay . | tar xf - && rm -rf /__overlay
RUN chown -R tluser:tluser /home/tluser

# Generate locale
RUN locale-gen

# Configure Plymouth theme to bgrt (keeps vendor logo, shows spinner below)
# The default bgrt theme works with EFI framebuffer
RUN printf '#!/bin/sh\nupdate-alternatives --query default.plymouth 2>/dev/null | grep "^Value:" | cut -d/ -f6 || echo bgrt\n' > /usr/sbin/plymouth-set-default-theme && \
    chmod +x /usr/sbin/plymouth-set-default-theme

# Remove SSH keys and enable services
# ssh.service is enabled explicitly even though 26.04 ships sshd as
# socket-activated (ssh.socket is enabled by the package). Socket activation
# alone means sshd only starts on the first inbound connection, so a broken
# sshd config or a missing host key shows up as a failed login rather than a
# logged unit failure at boot. Starting it eagerly makes such problems visible
# in `journalctl -b` on a machine whose graphical session may not be coming up.
# seatd is disabled deliberately. It arrives as a labwc dependency and enables
# itself, but this image has systemd-logind, which is the correct seat manager
# here: logind grants the active session ACL access to /dev/dri and /dev/input.
# With seatd also running, wlroots' libseat tries the seatd backend first, hits
# "could not access socket /run/seatd.sock: permission denied" because tluser is
# in no seat group, and only then falls back to logind. That produced an alarming
# error on every start and left DRM access depending on which backend won.
RUN systemctl disable seatd.service || true

RUN rm -f /etc/ssh/ssh_host_*_key* && \
    systemctl enable regenerate_ssh_host_keys || true && \
    systemctl enable ssh.service || true && \
    systemctl enable un-dockerize.service || true && \
    systemctl enable systemd-networkd && \
    systemctl enable systemd-resolved

# Build initramfs with dracut
# Keep it generic but omit unnecessary modules.
#
# --no-hostonly is required explicitly (not just implied by omitting --hostonly):
# dracut's own default is "hostonly=-h" unless hostonly is explicitly set to "no"
# (see /usr/bin/dracut: "hostonly shell variable defaults to -h if not specified").
# With that default active, every instmods call - including the ones in the dbrrg
# module below - gets silently filtered against a "hostonly module list" that dracut
# auto-detects from whatever happens to be loaded on the machine BUILDING the image
# (via the container's leaked /sys, since podman shares the host kernel). On this
# build host that dropped zram (not loaded here) and would have silently dropped
# needed NIC drivers (e1000/e1000e/igb/r8169/atlantic/iwlwifi) too, depending on
# what the build host happens to have loaded - fine on one machine, broken on
# another. --no-hostonly forces the true generic path this comment always intended.
RUN KERNEL_VERSION=$(ls /lib/modules | head -1) && \
    dracut --force --no-hostonly --add "dbrrg plymouth" \
    --omit "drm dash crypt dmraid multipath iscsi nfs nbd fcoe fcoe-uefi biosdevname dmsquash-live dmsquash-live-ntfs" \
    --omit-drivers "btrfs xfs reiserfs jfs ocfs2 gfs2 f2fs bcachefs cramfs minix hfs hfsplus qnx4 qnx6 ufs nouveau radeon amdgpu i915 vmwgfx qxl virtio-gpu bochs" \
    --compress "zstd -3 -T4" \
    --kver $KERNEL_VERSION

# Cleanup. Firmware content is determined by package selection alone -
# see the linux-firmware-minimal + per-vendor packages above. Never
# re-introduce a find/rm sweep over /usr/lib/firmware.
RUN rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* && \
    apt-get -qqy clean && apt-get -qqy autoremove
