#!/bin/sh
# The far end: a shared object built against musl, exporting one function.
# Nothing about it is special, and that is the point. It is what a host driver
# looks like from a glibc process's side of the fence.
set -eu
apk add --no-cache gcc musl-dev >/dev/null 2>&1
mkdir -p /work && cd /work

cat > hostlib.c <<'EOF'
#include <stdio.h>
#include <string.h>

/* Touches libc on both the entry and the exit, so a bridge that only got the
 * loading right and not the calling would show up here rather than pass. */
int host_answer(char *out, unsigned long n)
{
	snprintf(out, n, "the host object ran, and it is musl-built");
	return (int)strlen(out);
}
EOF

gcc -shared -fPIC -O2 hostlib.c -o hostlib.so
echo "built /work/hostlib.so"
echo "  NEEDED: $(readelf -d hostlib.so | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
