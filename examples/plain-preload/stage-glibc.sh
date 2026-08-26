#!/bin/sh
# Build cross-libc-dlopen.so on the glibc floor, plus an ordinary program that
# dlopens a library named on its command line. No AppDir is created and no
# marker file is written.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends gcc libc6-dev make python3 binutils \
	>/dev/null 2>&1

mkdir -p /build/src /build/inventories /build/tools
cp /repo/src/*.c /repo/src/*.h /repo/src/Makefile /build/src/
cp /repo/inventories/* /build/inventories/ 2>/dev/null || true
cp /repo/tools/* /build/tools/ 2>/dev/null || true
cd /build/src && make cross-libc-dlopen.so >/dev/null
cp cross-libc-dlopen.so /work/
echo "built /work/cross-libc-dlopen.so"
echo "  needs at most: $(objdump -T cross-libc-dlopen.so |
                         grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"

cd /work
cat > user.c <<'EOF'
/* An ordinary program. It knows nothing about this project: it dlopens what it
 * is told to and calls one symbol out of it. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: user <library>\n"); return 2; }

	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) { printf("FAILED: %s\n", dlerror()); return 1; }

	int (*answer)(char *, unsigned long) =
		(int (*)(char *, unsigned long))dlsym(h, "host_answer");
	if (!answer) { printf("FAILED: no host_answer: %s\n", dlerror()); return 1; }

	char buf[128];
	int n = answer(buf, sizeof buf);
	printf("OK: %s (%d bytes)\n", buf, n);
	return 0;
}
EOF
gcc -O2 user.c -o user -ldl
echo "built /work/user  (a normal glibc program; no bundle anywhere)"
