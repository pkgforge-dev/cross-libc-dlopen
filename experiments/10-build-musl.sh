#!/bin/sh
# Stage 1, running in Alpine (musl). Produces a faithful musl-linked probe library.
# Faithful matters: Debian's musl-gcc emits NEEDED "libc.so", which collides with
# glibc's linker script of the same name. Only a real Alpine build gives us
# NEEDED "libc.musl-x86_64.so.1" on x86-64 and "libc.musl-aarch64.so.1" on
# aarch64, which is what a host driver on Alpine looks like.
set -eu
apk add --no-cache gcc musl-dev binutils >/dev/null 2>&1
cd /work

cat > probe.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
static void bye(void){ fprintf(stderr, "  [probe] atexit handler ran\n"); }
__attribute__((constructor)) static void init(void){ atexit(bye); }
int probe_answer(void){ return 42; }
CEOF

gcc -shared -fPIC -O2 -Wl,-z,now probe.c -o libprobe.so

echo "== stage 1: Alpine-built probe =="
echo -n "   NEEDED   : "; readelf -dW libprobe.so | grep -oE '\[libc[^]]*\]' | tr -d '[]'
echo -n "   undefined: "; nm -D --undefined-only libprobe.so | awk '{print $2}' | tr '\n' ' '; echo
echo -n "   flags    : "; readelf -dW libprobe.so | grep -oE 'BIND_NOW|NOW' | head -1; echo
