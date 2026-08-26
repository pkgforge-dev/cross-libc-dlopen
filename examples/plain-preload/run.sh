#!/bin/sh
# A plain LD_PRELOAD against a normal binary. No AppDir, no marker file, no
# .preload, no launcher.
#
# ⭐ THIS IS THE STANDALONE CASE. Every measured result in docs/REPORT.md was
# obtained through an AppImage, which is the hardest consumer because it
# supplies its own loader. This shows the easiest one: an ordinary dynamically
# linked program on an ordinary host.
#
# WHAT IT MEASURES. A glibc process opens a musl-built shared object.
#
#   before  dlopen fails, naming musl's libc, which is not on this host
#   after   the same dlopen succeeds and the symbol in it is called
#
# ⚠ WHAT IT DOES NOT MEASURE. The object on the far end is a stand-in, not a
# host GPU driver. That is the difference between this and TODO/measurement.md
# T-03, and it is why the README's opening sentence is still about AppImages.
#
#   sh examples/plain-preload/run.sh
#
# Needs podman or docker. Nothing is installed on the host and nothing is
# written outside a temporary directory.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)

engine=''
for e in podman docker; do
	command -v "$e" >/dev/null 2>&1 && { engine=$e; break; }
done
[ -n "$engine" ] || { echo "needs podman or docker" >&2; exit 2; }

VOL=cross-libc-dlopen-example
"$engine" volume rm -f "$VOL" >/dev/null 2>&1 || true
trap '"$engine" volume rm -f "$VOL" >/dev/null 2>&1 || true' EXIT INT TERM

echo "== 1. build a musl object on Alpine =="
"$engine" run --rm -v "$VOL:/work" -v "$HERE:/x:ro" alpine:3.22 sh /x/stage-musl.sh

echo
echo "== 2. build the loader on the glibc floor, and a program that uses it =="
"$engine" run --rm -v "$VOL:/work" -v "$ROOT:/repo:ro" -v "$HERE:/x:ro" \
	debian:bullseye-slim sh /x/stage-glibc.sh

echo
echo "== 3. the A/B =="
"$engine" run --rm -v "$VOL:/work" -v "$HERE:/x:ro" \
	debian:bullseye-slim sh /x/stage-ab.sh
