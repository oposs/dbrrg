FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install -yq apt-utils
RUN apt-get update
# yes | unminimize
RUN apt-get install -yq \
    systemd-sysv \
    vim \
    openssh-server \
    sudo \
    iproute2 \
    curl \
    lsb-release \
    less \
    joe \
    net-tools \
    pciutils \
    iputils-ping \
    locales \
    rsync \
    unzip \
    initramfs-tools \
    pixz \
    curl \
    xorg \
    nodm \
    wm2 \
    numlockx \
    dialog \
    alsa-base \
    pulseaudio \
    lxterminal \
    plymouth \
    plymouth-theme-spinner \
    linux-image-generic
RUN apt-get -qq clean
RUN apt-get -qq autoremove
RUN wget https://www.cendio.com/downloads/clients/tl-4.14.0-clients.zip && \
    unzip tl-4.14.0-clients.zip tl-4.14.0-clients/client-linux-deb/thinlinc-client_4.14.0-2324_amd64.deb && \
     dpkg --install tl-4.14.0-clients/client-linux-deb/thinlinc-client_4.14.0-2324_amd64.deb && \
    rm -rf tl-4.14.0-clients.zip tl-4.14.0-clients
ADD overlay/ /__overlay
RUN cp -r /__overlay/* / && rm -rf /__overlay
RUN update-initramfs -c -k all
RUN locale-gen
RUN /bin/rm -f -v /etc/ssh/ssh_host_*_key* && \
    systemctl enable regenerate_ssh_host_keys && \
    systemctl enable un-dockerize.service && \
    systemctl enable systemd-networkd && \
    systemctl enable systemd-resolved

# Remove the divert that disables services
# RUN rm -f /sbin/initctl && dpkg-divert --local --rename --remove /sbin/initctl
RUN passwd -d root
RUN adduser --disabled-password --gecos "ThinUser" tluser
RUN adduser tluser sudo && \
    echo "tluser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
RUN adduser tluser audio