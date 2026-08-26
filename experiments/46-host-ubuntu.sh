#!/bin/sh
# A pre-glvnd GLIBC host. The third class, and until now the asserted one.
#
# alpine is musl + classic Mesa. debian:trixie is glibc + glvnd. Between them
# they leave exactly one of the two sentences in README and REPORT 9 unmeasured:
# "every musl distro, AND every pre-glvnd glibc distro". This script is the
# second half: old Ubuntu, glibc, Mesa with no libGLX_<vendor>.so.0 anywhere.
#
# ⚠ CONTINUE 4.0's B3 row says these images' repositories "moved to
# old-releases.ubuntu.com". They did not, and as of 2026-08 old-releases does
# not carry trusty or xenial AT ALL. It jumps from saucy to utopic, and every
# dists/trusty/... path 404s. Both releases are still in their ESM window, so
# they are still served from archive.ubuntu.com at the DEFAULT path: the
# sources.list rewrite the row prescribes is what breaks them. What does have to
# go is the ESM source the image ships, which points at esm.ubuntu.com and needs
# credentials nobody here has; apt then fails the whole update and every package
# "cannot be located", which reads exactly like a dead mirror.
#
#   ubuntu:14.04   glibc 2.19   Mesa 10.1.3   python3.4
#   ubuntu:16.04   glibc 2.23   Mesa 18.0.5   python3.5
#
# Neither has a software Vulkan ICD, because Mesa 10.1 predates Vulkan entirely, so
# 40-appimage.sh SKIPS the cases that need a device by name and runs the rest.
# Neither has python 3.6, so E59 and E60 skip too; both measure the BUNDLE
# rather than the host, and the other two hosts establish them.
set -u

rm -f /etc/apt/sources.list.d/*esm* /etc/apt/sources.list.d/*ubuntu-esm*
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1

# libgl1-mesa-glx is classic Mesa's libGL, and on the alternatives layout it
# lands in /usr/lib/<triplet>/mesa with libEGL in .../mesa-egl, and the two
# directories that made the shim's hardcoded list wrong (PR #4). Both are named
# by /etc/ld.so.conf.d/, which is how the shim finds them now.
apt-get install -y -qq --no-install-recommends \
    libgl1-mesa-glx libgl1-mesa-dri libegl1-mesa mesa-utils \
    gcc libc6-dev libgl1-mesa-dev libegl1-mesa-dev libx11-dev \
    xvfb xauth python3 procps >/dev/null 2>&1

echo "  host: $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)"
echo "  glibc $(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')  mesa $(dpkg-query -W -f='${Version}' libgl1-mesa-glx 2>/dev/null)  $(python3 -V 2>&1)"
echo "  ld.so.conf.d names: $(cat /etc/ld.so.conf.d/*GL*.conf 2>/dev/null | tr '\n' ' ')"

exec sh /scripts/40-appimage.sh
