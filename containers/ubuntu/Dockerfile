FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive

# Update and install base packages in single layer to avoid stale cache
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
    iproute2 \
    wireless-tools \
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
    xorg \
    nodm \
    wm2 \
    dialog \
    numlockx \
    alsa-base \
    pulseaudio \
    lxterminal \
    plymouth \
    plymouth-themes \
    plymouth-theme-spinner \
    intel-microcode \
    xserver-xorg-video-intel \
    linux-image-generic \
    linux-modules-iwlwifi-generic \
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
    python3

# Set ping setuid
RUN chmod u+s /usr/bin/ping

# Install ThinLinc
RUN wget https://www.cendio.com/downloads/clients/thinlinc-client_4.19.0-4005_amd64.deb && \
    apt install -y ./thinlinc-client_4.19.0-*_amd64.deb && \
    rm -f tl-*deb

# Remove root password
RUN passwd -d root

# Create user with simple password for console login
RUN adduser --disabled-password --gecos "ThinUser" tluser && \
    echo "tluser:tluser" | chpasswd && \
    adduser tluser sudo && \
    echo "tluser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    adduser tluser audio

# Disable pulseaudio auto-start
RUN sudo -u tluser systemctl --user disable pulseaudio.service pulseaudio.socket || true

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
# Keep it generic (no --hostonly) but omit unnecessary modules
RUN KERNEL_VERSION=$(ls /lib/modules | head -1) && \
    dracut --force --add "dbrrg plymouth" \
    --omit "drm dash crypt dmraid multipath iscsi nfs nbd fcoe fcoe-uefi biosdevname dmsquash-live dmsquash-live-ntfs" \
    --omit-drivers "btrfs xfs reiserfs jfs ocfs2 gfs2 f2fs bcachefs cramfs minix hfs hfsplus qnx4 qnx6 ufs nouveau radeon amdgpu i915 vmwgfx qxl virtio-gpu bochs" \
    --compress "zstd -3 -T0" \
    --kver $KERNEL_VERSION

# Cleanup - remove unnecessary firmware (keep only Intel NUC essentials)
# Whitelist approach: keep iwlwifi, i915, intel-ucode, intel/sof*, and remove everything else
# This saves ~450MB
RUN cd /usr/lib/firmware && \
    mkdir -p /tmp/fw-keep && \
    mv iwlwifi-* i915 intel intel-ucode /tmp/fw-keep/ 2>/dev/null || true && \
    rm -rf /usr/lib/firmware/* && \
    mv /tmp/fw-keep/* /usr/lib/firmware/ && \
    rm -rf /tmp/fw-keep && \
    rm -rf /usr/lib/firmware/intel/{ice,vpu,vsc,ipu} && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* && \
    apt-get -qqy clean && apt-get -qqy autoremove
