#!/bin/sh
# Build every artefact, from any host libc, for any target libc.
#
# THE FLOOR RULE, and it is about the BUNDLE rather than the host: build on a
# glibc no newer than the oldest bundled glibc you will load into. A build on
# glibc 2.41 needs GLIBC_2.34 and then fails to load inside a bundle carrying
# 2.31, at dlopen time and in somebody else's application. The host underneath
# can be as old as it likes. docs/building.md has the measurement.
#
#   scripts/build.sh                     container build for the host arch
#   scripts/build.sh --arch aarch64      cross-build, container
#   scripts/build.sh --arch both         both, sequentially
#   scripts/build.sh --engine native     no container; refuses if the host
#                                        libc is newer than --floor-glibc
#   scripts/build.sh --portable          reads only CROSS_LIBC_DLOPEN_ROOT and
#                                        no CET flag. `make portable` is the
#                                        same build without this script
#   scripts/build.sh --check             detect and report, build nothing
#
# Everything it produces lands in build/<arch>/ with a manifest beside it.
set -eu

# ---------------------------------------------------------------- defaults --
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname -- "$HERE")

ENGINE=auto
ARCH=
FLOOR_IMAGE=debian:bullseye-slim
FLOOR_GLIBC=2.31
OUT=
CHECK_ONLY=0
KEEP_GOING=0
# The build variant. "default" reads APPDIR as well as CROSS_LIBC_DLOPEN_ROOT,
# because an AppImage runtime exports APPDIR into every process it starts.
# "portable" reads only this project's own name, which is what a consumer who
# wants one spelling asked for; src/cld-env.h has the argument.
VARIANT=default
EXTRA_CFLAGS=
# ⭐ The portable variant also drops -fcf-protection=full. Measured in
# docs/report/09-the-second-boundary.md 9.13: the flag emits endbr64 and no IBT property note, the
# note cannot be emitted honestly because glibc's crti.o carries none, and
# without it a CET-enforcing loader does not turn IBT on for the object. So the
# instructions do no protective work, and a consumer targeting a kernel or an
# emulation layer that would rather not see them can have a build without.
NO_CET=0

die()  { printf 'build: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--engine)      ENGINE=${2:?--engine needs a value}; shift 2 ;;
		--arch)        ARCH=${2:?--arch needs a value}; shift 2 ;;
		--floor-image) FLOOR_IMAGE=${2:?--floor-image needs a value}; shift 2 ;;
		--floor-glibc) FLOOR_GLIBC=${2:?--floor-glibc needs a value}; shift 2 ;;
		--out)         OUT=${2:?--out needs a value}; shift 2 ;;
		--check)       CHECK_ONLY=1; shift ;;
		--keep-going)  KEEP_GOING=1; shift ;;
		--portable)  VARIANT=portable; EXTRA_CFLAGS=-DCLD_STRICT_ENV; NO_CET=1; shift ;;
		-h|--help)     usage 0 ;;
		*)             printf 'build: unknown option %s\n' "$1" >&2; usage 2 ;;
	esac
done

host_arch=$(uname -m)
[ -n "$ARCH" ] || ARCH=$host_arch

case "$ARCH" in
	x86_64|aarch64|both) ;;
	*) die "--arch must be x86_64, aarch64 or both (got '$ARCH')" ;;
esac

# ------------------------------------------------------- step 1: detection --
# A script that fails at step nine because a tool was missing at step one is
# worse than one that refuses at step one. Everything is probed and reported
# BEFORE anything is built.
have() { command -v "$1" >/dev/null 2>&1; }

detect_engine() {
	# Honour an explicit choice, and say why an explicit choice is unusable
	# rather than silently falling back to another one.
	case "$ENGINE" in
		podman|docker)
			have "$ENGINE" || die "--engine $ENGINE, but $ENGINE is not on PATH"
			printf '%s' "$ENGINE"; return ;;
		native)
			printf 'native'; return ;;
		auto) ;;
		*) die "--engine must be podman, docker, native or auto" ;;
	esac
	for e in podman docker; do
		if have "$e"; then printf '%s' "$e"; return; fi
	done
	printf 'native'
}

host_glibc() {
	# getconf is in glibc's own package and answers without compiling anything.
	if have getconf && getconf GNU_LIBC_VERSION 2>/dev/null | grep -q '^glibc'; then
		getconf GNU_LIBC_VERSION | awk '{print $2}'
		return
	fi
	# ldd exists on musl and on MSYS too and answers with THEIR version, which
	# compared against a glibc floor is a number that means nothing. Only take
	# it when the banner says GNU.
	if have ldd && ldd --version 2>&1 | head -1 | grep -qiE 'GNU libc|GLIBC'; then
		ldd --version 2>&1 | head -1 | awk '{print $NF}'
		return
	fi
	printf 'unknown'
}

# First of the named tools that exists, with its version line, or "none".
first_cc() {
	for c in "${CC:-}" cc gcc clang; do
		[ -n "$c" ] || continue
		if have "$c"; then
			printf '%s (%s)' "$c" "$("$c" --version 2>/dev/null | head -1)"
			return
		fi
	done
	printf 'none'
}

py_version() {
	have python3 || { printf 'none'; return; }
	v=$(python3 --version 2>&1 | head -1)
	case "$v" in
		Python\ [0-9]*) printf '%s' "$v" ;;
		*) printf 'present but unusable (%s)' "$(printf '%s' "$v" | cut -c1-40)" ;;
	esac
}

# Compare two dotted versions: 0 if $1 <= $2.
ver_le() {
	[ "$1" = "$2" ] && return 0
	lo=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
	[ "$lo" = "$1" ]
}

head_ "what is available"
engine=$(detect_engine)
note "host arch          : $host_arch"
note "target arch        : $ARCH"
note "container engine   : $(have podman && echo 'podman yes' || echo 'podman no'), $(have docker && echo 'docker yes' || echo 'docker no')"
note "chosen engine      : $engine"
note "host cc            : $(first_cc)"
note "host glibc         : $(host_glibc)"
note "aarch64 cross gcc  : $(have aarch64-linux-gnu-gcc && echo yes || echo no)"
note "qemu-aarch64-static: $(have qemu-aarch64-static && echo yes || echo no)"
note "python3            : $(py_version)"
note "floor image        : $FLOOR_IMAGE (glibc $FLOOR_GLIBC)"

if [ "$engine" = native ]; then
	hg=$(host_glibc)
	if [ "$hg" = unknown ]; then
		die "native build asked for and the host glibc could not be read. Pass --engine podman/docker, or --floor-glibc to assert one deliberately."
	fi
	if ! ver_le "$hg" "$FLOOR_GLIBC"; then
		die "REFUSING: this host has glibc $hg, newer than the requested floor $FLOOR_GLIBC.
      A build here would emit references to symbol versions the floor does not
      have, and the artefact would fail to load inside a bundle rather than
      fail here. Either build in a container (drop --engine native) or state
      the real floor with --floor-glibc $hg and accept that the artefacts will
      not load under anything older."
	fi
	note "native build allowed: host glibc $hg <= floor $FLOOR_GLIBC"
fi

if [ "$CHECK_ONLY" = 1 ]; then
	head_ "check only, nothing built"
	exit 0
fi

# --------------------------------------------------------- step 2: building --
build_one() {                          # build_one <arch>
	a=$1
	# A variant goes in its own directory. Two builds of the same
	# architecture into one place would leave a manifest describing files
	# that the other build had already overwritten.
	if [ "$VARIANT" = default ]; then dir=$a; else dir=$a-$VARIANT; fi
	out=${OUT:-$ROOT/build/$dir}
	mkdir -p "$out"
	head_ "building $a ($VARIANT) into $out"

	if [ "$engine" = native ]; then
		[ "$a" = "$host_arch" ] || die "native builds cannot target $a from $host_arch; use a container"
		CLD_OUT="$out" CLD_ARCH="$a" CLD_FLOOR_GLIBC="$FLOOR_GLIBC" \
		CLD_VARIANT="$VARIANT" CLD_EXTRA_CFLAGS="$EXTRA_CFLAGS" \
		CLD_NO_CET="$NO_CET" \
			sh "$HERE/build-in-env.sh" "$ROOT"
		return
	fi

	# --platform is deliberately NOT used to get another architecture: pulling
	# a tag for another platform REPLACES the cached image for that tag, and
	# the next native job using it dies with "Exec format error". The aarch64
	# artefacts are CROSS-COMPILED inside an x86-64 floor image instead.
	"$engine" run --rm \
		-v "$ROOT:/repo:ro" \
		-v "$out:/out" \
		-e CLD_OUT=/out \
		-e CLD_ARCH="$a" \
		-e CLD_FLOOR_GLIBC="$FLOOR_GLIBC" \
		-e CLD_INSTALL_DEPS=1 \
		-e CLD_VARIANT="$VARIANT" \
		-e CLD_EXTRA_CFLAGS="$EXTRA_CFLAGS" \
		-e CLD_NO_CET="$NO_CET" \
		"$FLOOR_IMAGE" sh /repo/scripts/build-in-env.sh /repo
}

rc=0
if [ "$ARCH" = both ]; then
	for a in x86_64 aarch64; do
		if build_one "$a"; then :; else
			rc=1
			[ "$KEEP_GOING" = 1 ] || exit 1
		fi
	done
else
	build_one "$ARCH" || rc=1
fi

head_ "done"
[ "$rc" = 0 ] && note "every artefact built and verified" || note "at least one target failed"
exit "$rc"
