#!/bin/sh
# Build the preload and the probes on the OLDEST supported glibc, so they only
# ever need symbols the AppImage's bundled runtime is guaranteed to have.
set -eu
# Same bootstrap rule as stages 2 and 3: bullseye comes from
# archive.debian.org because deb.debian.org's bullseye-security pool is being
# emptied while its indices still list the emptied versions (measured
# 2026-09-06), and the apt output is kept so a failed toolchain fails the
# stage naming itself instead of failing every later build with a missing
# file. http, not https, because the slim image ships no CA store.
printf '%s\n' 'deb http://archive.debian.org/debian bullseye main' \
	> /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*.sources 2>/dev/null || true
apt-get update -qq -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 \
	>/w/.apt4-update.log 2>&1 || true
apt-get install -y -qq -o Acquire::Retries=3 --no-install-recommends \
    gcc libc6-dev make python3 binutils libgl1-mesa-dev libegl1-mesa-dev \
    libx11-dev >/w/.apt4-install.log 2>&1 || true
for _tool in gcc make python3 readelf; do
    command -v "$_tool" >/dev/null 2>&1 || {
        echo "STAGE 42 CANNOT RUN: $_tool did not install; the apt output follows" >&2
	sed 's/^/  update| /' /w/.apt4-update.log >&2
	sed 's/^/  install| /' /w/.apt4-install.log >&2
	exit 2
    }
done
mkdir -p /build/src && cd /build/src
cp /repo/src/*.c /repo/src/*.h /repo/src/Makefile .
mkdir -p /build/inventories /build/tools
cp /repo/inventories/* /build/inventories/ 2>/dev/null || true
cp /repo/tools/* /build/tools/ 2>/dev/null || true
make 2>&1 | tail -3
mkdir -p /w/build
cp cross-libc-dlopen.so runtime-select gl-fwd.so egl-fwd.so gles-fwd.so /w/build/
for t in icd-harness vkprobe corpus invariants soak cudaprobe bindprobe; do
    gcc -O2 -o /w/build/$t /repo/tests/$t.c -ldl
done
# The GL and EGL probes. They link the BUNDLED sonames, libGL.so.1 and
# libEGL.so.1, which is what puts the shim under test: ld.so binds those
# DT_NEEDED entries to whatever claims the soname in the process, and the shim
# is built with exactly those sonames.
gcc -O2 -o /w/build/glprobe  /repo/tests/glprobe.c  -lGL -lX11
gcc -O2 -o /w/build/eglprobe /repo/tests/eglprobe.c -lEGL -lGL
# The cross-libc ABI probe: the driver, and the SAME-libc guest that is its
# control. -I so both find abi-abi.h, which carries the shared view struct and
# the one filler both sides are compiled from.
gcc -O2 -I/repo/tests -o /w/build/abi-host /repo/tests/abi-host.c -ldl -lpthread
gcc -shared -fPIC -O2 -Wl,-z,now -I/repo/tests /repo/tests/abi-guest.c     -o /w/build/libabi_glibc.so -lpthread
echo "floor build ok. preload needs at most: $(objdump -T cross-libc-dlopen.so | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
