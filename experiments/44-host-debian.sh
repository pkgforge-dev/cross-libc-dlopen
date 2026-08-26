#!/bin/sh
# glibc host, OLDER than the AppImage's bundled glibc, so no host object NEEDS
# rewriting. Turning the feature on must not break what already worked.
#
# libglx-mesa0 brings libglvnd's vendor library, so this host is the OTHER GL
# class: the bundled dispatcher has something to dispatch to and OpenGL works
# as shipped. That makes section J's cases a transparency test here, where the shim
# must change nothing, rather than a repair, and E61/E63 predict success
# instead of the classic-host failure.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
    mesa-vulkan-drivers libvulkan1 vulkan-tools mesa-utils \
    libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libegl1 \
    python3 procps \
    gcc libc6-dev libgl-dev libegl-dev libx11-dev \
    xvfb xauth >/dev/null 2>&1
exec sh /scripts/40-appimage.sh
