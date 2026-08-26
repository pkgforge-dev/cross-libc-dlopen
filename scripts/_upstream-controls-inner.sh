#!/bin/sh
# The container half of scripts/verify-upstream-controls.sh. Not run directly.
set -eu
APPDIR=/w/AppDir
LP=$APPDIR/lib
# The bundled loader and lavapipe's ICD manifest both carry the architecture.
case "$(uname -m)" in
	x86_64)  LDSO=ld-linux-x86-64.so.2 ; ICD_ARCH=x86_64  ;;
	aarch64) LDSO=ld-linux-aarch64.so.1; ICD_ARCH=aarch64 ;;
	*) echo "no loader and ICD name known for $(uname -m)" >&2; exit 1 ;;
esac
LD=$LP/$LDSO
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR"
apk add --no-cache mesa-vulkan-swrast binutils >/dev/null 2>&1 || true

# Upstream's own shim, in the slot .preload names. This is what E30, E37a and
# E43a run.
cp "$LP/foreign-dlopen.upstream.so" "$LP/foreign-dlopen.so"

echo "-- the variable names upstream's binary actually reads --"
strings -a "$LP/foreign-dlopen.upstream.so" |
	grep -E '^(ANYLINUX|CROSS_LIBC)' | sort -u | sed 's/^/   /'
echo

ICD=/usr/share/vulkan/icd.d/lvp_icd.$ICD_ARCH.json

# ⚠ The count goes in a variable, NOT down stdout. An earlier version of this
# function printed its report and then echoed the number, and the caller's
# $( ) swallowed both -- so the comparison was against a paragraph and the
# script declared the controls broken while the measurement in front of it
# said 85. A function that reports AND returns down the same channel returns
# its report.
ARM_N=0
arm() {                                # arm <label> <env...>; sets ARM_N
	label=$1; shift
	out=$(env "$@" APPDIR="$APPDIR" VK_DRIVER_FILES="$ICD" \
	      "$LD" --library-path "$LP" --preload "$LP/foreign-dlopen.so" \
	      /w/build/vkprobe 2>&1 || true)
	ARM_N=$(printf '%s\n' "$out" | grep -c 'foreign:' || true)
	printf '   %-46s upstream debug lines: %s\n' "$label" "$ARM_N"
	printf '%s\n' "$out" | grep 'foreign:' | head -2 | sed 's/^/      /'
}

echo "-- both arms --"
arm "A: both names, as the harness sends them" \
	CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 \
	CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1
a=$ARM_N
arm "B: new names only -- the silent-pass shape" \
	CROSS_LIBC_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1
b=$ARM_N

echo
if [ "$a" -gt 0 ] && [ "$b" -eq 0 ]; then
	echo "   PROVEN: the old names are load-bearing for these controls."
	echo "   Arm A reaches upstream ($a lines); arm B does not reach it at all,"
	echo "   and E30 would still have reported NO-DEVICES and gone green."
	exit 0
fi
if [ "$a" -gt 0 ] && [ "$b" -gt 0 ]; then
	echo "   INCONCLUSIVE: both arms reached upstream. Either this AppImage's"
	echo "   shim now reads the new names too, or the arms are not isolated."
	exit 1
fi
echo "   BROKEN: arm A did not reach upstream either ($a lines). The controls"
echo "   are measuring nothing right now. Investigate before trusting E30."
exit 1
