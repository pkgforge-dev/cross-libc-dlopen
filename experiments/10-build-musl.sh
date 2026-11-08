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

# A musl-built object that imports the crypt family. musl keeps those inside
# libc.so, so this imports them with NO DT_NEEDED on anything, which is the
# shape that dangles once cross-libc-dlopen drops the libc edge. E107 and E108
# in stage 3 are the cases; src/crypt-shim.c is the answer.
cat > muslcrypt.c <<'CEOF'
#include <crypt.h>
#include <string.h>
#define WANT "$6$s$uS8ebqSHbt1SxeJHmjJJ8XiNODU1MHXmq8vuR.PTjWjqzI2O0O5Fqib4lhr5K8OJ/hMYgFNUo1BLK3I7X/8yn/"
static int ok(const char *h){ return h && strcmp(h, WANT) == 0; }
int musl_crypt_call(void){ return ok(crypt("password", "$6$s")) ? 42 : 1; }
int musl_crypt_r_call(void){ static struct crypt_data d; d.initialized = 0;
    return ok(crypt_r("password", "$6$s", &d)) ? 42 : 1; }
CEOF
gcc -shared -fPIC -O2 muslcrypt.c -o libmuslcrypt.so -lcrypt

echo "== stage 1: Alpine-built probe =="
echo -n "   NEEDED   : "; readelf -dW libprobe.so | grep -oE '\[libc[^]]*\]' | tr -d '[]'
echo -n "   undefined: "; nm -D --undefined-only libprobe.so | awk '{print $2}' | tr '\n' ' '; echo
echo -n "   flags    : "; readelf -dW libprobe.so | grep -oE 'BIND_NOW|NOW' | head -1; echo
echo -n "   crypt    : "; nm -D --undefined-only libmuslcrypt.so | awk '{print $2}' | tr '\n' ' '; echo
