FROM ubuntu:26.04
ARG DEBIAN_FRONTEND=noninteractive

# Update and install base packages in single layer to avoid stale cache.
#
# xcursor-themes ships the only Xcursor pointer theme in this image. It used
# to arrive transitively via lxterminal (GTK) / xorg; both are gone now, so
# without it labwc has no cursor image to load and the pointer is invisible.
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
    labwc \
    xwayland \
    foot \
    foot-terminfo \
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
RUN rm -f /etc/ssh/ssh_host_*_key* && \
    systemctl enable regenerate_ssh_host_keys || true && \
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
