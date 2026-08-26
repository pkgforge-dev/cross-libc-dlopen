#!/bin/sh
# The half of the build that runs INSIDE the floor environment, whether a container
# by default, the host itself for `build.sh --engine native`. Never invoked
# directly; scripts/build.sh sets everything it reads.
#
#   $1                  the repository root (read-only is fine)
#   CLD_OUT             where the artefacts and the manifest go
#   CLD_ARCH            x86_64 | aarch64
#   CLD_FLOOR_GLIBC     the floor being asserted, for the manifest
#   CLD_INSTALL_DEPS    1 to apt-get what is missing (containers only)
set -eu

REPO=${1:?usage: build-in-env.sh <repo-root>}
OUT=${CLD_OUT:?CLD_OUT unset}
ARCH=${CLD_ARCH:-$(uname -m)}
FLOOR=${CLD_FLOOR_GLIBC:-unknown}

die() { printf 'build-in-env: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ prerequisites --
if [ "${CLD_INSTALL_DEPS:-0}" = 1 ]; then
	pkgs='gcc libc6-dev make python3 binutils'
	[ "$ARCH" = aarch64 ] && pkgs="$pkgs gcc-aarch64-linux-gnu libc6-dev-arm64-cross"
	# libc6-dev-arm64-cross is not optional: the cross compiler alone has no
	# headers and the build dies on dirent.h, which reads like a source bug.
	# ⛔ NEITHER OF THESE DISCARDS ITS OUTPUT ANY MORE, and that is T-13's
	# shape for the fourth time in this tree. Both were `>/dev/null 2>&1`, so
	# a failure printed "could not install:" followed by the package list and
	# nothing about the cause. Measured: build aarch64 (docker) failed exactly
	# that way and the log could not distinguish a mirror having a bad minute
	# from bullseye's archives having moved, which are a retry and an
	# emergency respectively.
	#
	# ⚠ The update's own failure is now fatal on its own. It used to be
	# ignored, so a package list that never downloaded surfaced one line later
	# as an install failure, which names the wrong step.
	export DEBIAN_FRONTEND=noninteractive
	if ! apt-get update -qq >/tmp/cld-apt-update.log 2>&1; then
		printf 'build-in-env: apt-get update failed. Its output:\n' >&2
		sed 's/^/  | /' /tmp/cld-apt-update.log >&2
		die "no package list, so the prerequisites cannot be installed"
	fi
	# shellcheck disable=SC2086
	if ! apt-get install -y -qq --no-install-recommends $pkgs >/tmp/cld-apt-install.log 2>&1; then
		printf 'build-in-env: apt-get install failed. Its output:\n' >&2
		sed 's/^/  | /' /tmp/cld-apt-install.log >&2
		die "could not install: $pkgs"
	fi
fi

case "$ARCH" in
	x86_64)  CC=${CC:-gcc};                    NM=nm;                    OBJDUMP=objdump ;;
	aarch64)
		if [ "$(uname -m)" = aarch64 ]; then
			CC=${CC:-gcc}; NM=nm; OBJDUMP=objdump
		else
			CC=aarch64-linux-gnu-gcc
			NM=aarch64-linux-gnu-nm
			OBJDUMP=aarch64-linux-gnu-objdump
		fi ;;
	*) die "unsupported arch '$ARCH'" ;;
esac
command -v "$CC" >/dev/null 2>&1 || die "no $CC on PATH"
command -v python3 >/dev/null 2>&1 || die "no python3 on PATH"

# ------------------------------------------------------------------- build --
# Built in a scratch copy so a read-only /repo mount works and so a second run
# starts from the same state as the first (idempotence, task 3.5).
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/src" "$WORK/inventories" "$WORK/tools"
cp "$REPO"/src/*.c "$REPO"/src/*.h "$REPO"/src/Makefile "$WORK/src/"
cp "$REPO"/src/forward-shim-manifest.json "$WORK/src/" 2>/dev/null || true
cp "$REPO"/inventories/* "$WORK/inventories/" 2>/dev/null || true
cp "$REPO"/tools/* "$WORK/tools/" 2>/dev/null || true

printf 'building for %s with %s%s\n' "$ARCH" "$($CC --version | head -1)" \
	"${CLD_EXTRA_CFLAGS:+ [variant: $CLD_EXTRA_CFLAGS]}"
# ⚠ CET_CFLAGS= on the command line overrides the Makefile's `:=`, which is
# how the portable variant drops -fcf-protection=full. An empty value here is
# not the same as leaving it out: leaving it out lets the Makefile decide.
if [ "${CLD_NO_CET:-0}" = 1 ]; then
	( cd "$WORK/src" && make CC="$CC" EXTRA_CFLAGS="${CLD_EXTRA_CFLAGS:-}" CET_CFLAGS= >/dev/null ) ||
		die "make failed for $ARCH"
else
	( cd "$WORK/src" && make CC="$CC" EXTRA_CFLAGS="${CLD_EXTRA_CFLAGS:-}" >/dev/null ) ||
		die "make failed for $ARCH"
fi

mkdir -p "$OUT"
for f in cross-libc-dlopen.so gl-fwd.so egl-fwd.so gles-fwd.so runtime-select; do
	[ -f "$WORK/src/$f" ] || die "make produced no $f"
	cp "$WORK/src/$f" "$OUT/$f"
done

# ------------------------------------------------------- verify, not assume --
# Every artefact is checked AFTER it is built, against the three properties
# that make it either work or fail silently: the SONAME ld.so will bind to,
# the number of entry points the table promised, and the highest GLIBC_ symbol
# version it ended up needing. The third is the floor rule, measured.
CLD_NM="$NM" CLD_OBJDUMP="$OBJDUMP" \
CLD_ARCH="$ARCH" CLD_FLOOR_GLIBC="$FLOOR" CLD_SRC="$WORK/src" CLD_CC="$CC" \
CLD_VARIANT="${CLD_VARIANT:-default}" \
	sh "$REPO/scripts/verify-artifacts.sh" "$OUT" "$REPO"
