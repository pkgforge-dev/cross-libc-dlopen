#!/bin/sh
# Build the cross-libc ABI guest on Alpine, so it is a FAITHFUL musl object.
#
# Faithful matters, and 10-build-musl.sh says why: Debian's musl-gcc emits
# NEEDED "libc.so", which collides with glibc's linker script of the same name.
# Only a real Alpine build gives NEEDED "libc.musl-x86_64.so.1", or on aarch64
# "libc.musl-aarch64.so.1", which is what a host driver on Alpine actually
# looks like.
#
# The result goes into /w/build, so BOTH host stages can load it: on Alpine it
# is a host-native object, and on Debian it isolates "the object is musl-built"
# from "the host is musl", which are two different claims.
set -eu
apk add --no-cache gcc musl-dev binutils >/dev/null 2>&1
mkdir -p /w/build
gcc -shared -fPIC -O2 -Wall -Wextra -Wl,-z,now -I/repo/tests \
    /repo/tests/abi-guest.c -o /w/build/libabi_musl.so
echo "musl ABI guest: NEEDED $(readelf -dW /w/build/libabi_musl.so | grep -oE '\[libc[^]]*\]' | tr -d '[]')"
