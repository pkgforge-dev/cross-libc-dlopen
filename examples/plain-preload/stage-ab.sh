#!/bin/sh
# The A/B. Same program, same object, same host. One variable.
#
# ⚠ A single-sided result cannot tell a working fix from something that was
# already happening, which is why BOTH halves are run and printed every time.
set -eu
cd /work

echo
echo "--- BEFORE: no preload -------------------------------------------"
echo '$ ./user /work/hostlib.so'
./user /work/hostlib.so || true

echo
echo "--- AFTER: LD_PRELOAD, and one variable --------------------------"
echo '$ LD_PRELOAD=/work/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 ./user /work/hostlib.so'
LD_PRELOAD=/work/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 ./user /work/hostlib.so
rc=$?

echo
echo "--- what it did --------------------------------------------------"
LD_PRELOAD=/work/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 \
	CROSS_LIBC_DLOPEN_DEBUG=1 ./user /work/hostlib.so 2>&1 |
	grep 'cross-libc-dlopen:' || echo "(no debug lines)"

echo
echo "--- the control: preloaded, feature OFF --------------------------"
echo "The object is loaded and the switch is 0. If this also succeeded, the"
echo "'after' above would be proving nothing."
echo '$ LD_PRELOAD=/work/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=0 ./user /work/hostlib.so'
LD_PRELOAD=/work/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=0 ./user /work/hostlib.so || true

echo
echo "--- no bundle was involved ---------------------------------------"
echo "APPDIR                    = ${APPDIR:-(unset)}"
echo "CROSS_LIBC_DLOPEN_ROOT    = ${CROSS_LIBC_DLOPEN_ROOT:-(unset)}"
echo "marker files in /work     : $(ls -a /work | grep -c 'enabled$' || true)"

exit "$rc"
