#!/bin/sh
# The end-to-end proof: a real AppImage using a real HOST graphics driver on a
# host whose libc is not the AppImage's.
#
# run-evidence.sh measures the mechanism in isolation. This measures the thing
# users actually complain about, on real software, across four host classes and
# a second AppImage:
#
#   debian:bullseye-slim  builds the artefacts on the glibc 2.31 FLOOR
#   alpine:3.22           musl host -- the case the complaint is about
#   debian:trixie-slim    glibc 2.41, OLDER than the bundled 2.44, so nothing
#                         NEEDS rewriting. The regression case.
#   ubuntu:14.04          pre-glvnd glibc: classic Mesa, no libGLX_<vendor>,
#   ubuntu:16.04          no Vulkan. The third host CLASS.
#   gtk4-demo             a real GTK4 application that bundles its own Mesa and
#                         is the only AppDir here carrying libGLESv2.so.2
#
#   scripts/run-appimage.sh                    everything
#   scripts/run-appimage.sh --only alpine      one host
#   CLD_TARGET_ARCH=aarch64 scripts/run-appimage.sh
#
# Tens of minutes: two downloads and apt/apk on four distributions, two of
# which are from 2014 and 2016. run-evidence.sh is the fast gate; this is not.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname -- "$HERE")
STAGES=$ROOT/experiments
WORK=${CLD_WORK:-$ROOT/.tmp}
. "$HERE/suite-lib.sh"

ONLY=all
while [ $# -gt 0 ]; do
	case "$1" in
		--only) ONLY=${2:?--only needs a value}; shift 2 ;;
		-h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1" ;;
	esac
done
case "$ONLY" in
	alpine|debian|ubuntu1404|ubuntu1604|gtk4|both|all) ;;
	*) die "--only must be alpine, debian, ubuntu1404, ubuntu1604, gtk4, both or all" ;;
esac

# ---------------------------------------------------- the pinned downloads --
# One sha256 PER ARCHITECTURE, each computed from the asset itself. Copying a
# number out of a document is how a pin stops being a pin.
ARCH=$(asset_suffix)
BASE=https://github.com/Samueru-sama/Anylinux-AppImages/releases/download/demo
case "$ARCH" in
	x86_64)
		DEMO_SHA=712766f8a4dc6b5ea3193ed7bb0282b64c7b781f7334056416edd3d00e8960bd
		GTK4_SHA=577909eff286b385dc0e3dc1eda0ef42f92858418c449e89e426ef950a63eb89 ;;
	aarch64)
		DEMO_SHA=12a64183fc36990aae265be38f0472d7e3d73d5622b6d0b17fb355aad8ba7130
		GTK4_SHA=69fd76c0f1d47f2a7516d2b7909cf0bd346f64368de39d14e9093426526a42be ;;
esac
DEMO_URL="$BASE/vkcube+glxgears-host-drivers-demo-$ARCH.AppImage"
GTK4_URL="$BASE/gtk4-demo-$ARCH.AppImage"

engine=$(resolve_engine)
say "engine: $engine"
say "target arch: $ARCH"
mkdir -p "$WORK" "$WORK/build" "$WORK/gtk4x"
probe_gpu "$engine"

in_container() {                       # in_container <image> <script> [flags...]
	_img=$1; _scr=$2; shift 2
	assert_lf "$STAGES/$_scr"
	info "==> $_img  ($_scr)"
	# shellcheck disable=SC2086
	"$engine" run --rm \
		-v "$WORK:/w" \
		-v "$ROOT:/repo:ro" \
		-v "$STAGES:/scripts:ro" \
		"$@" \
		"$_img" sh "/scripts/$_scr"
}

fetch_verified "$DEMO_URL" "$WORK/demo.AppImage" "$DEMO_SHA" "demo.AppImage ($ARCH)"

# Extraction runs the AppImage's own ELF runtime and the payload is DwarFS, so
# it happens inside a container. --privileged: hosted runners allow it, a
# hardened self-hosted one may not, and then this is the first thing to break.
if [ ! -d "$WORK/AppDir" ]; then
	in_container debian:trixie-slim 41-extract.sh --privileged ||
		die "extraction failed"
fi

in_container debian:bullseye-slim 42-build-floor.sh      || die "floor build failed"
in_container alpine:3.22          45-build-musl-guest.sh || die "musl guest build failed"

fail=0
host_case() {                          # host_case <image> <script> <banner>
	say ""
	warn "######## $3 ########"
	# shellcheck disable=SC2086
	in_container "$1" "$2" $GPU_ARGS || fail=$((fail + 1))
}

case "$ONLY" in both|all|alpine)
	host_case alpine:3.22 43-host-alpine.sh "musl host: the case the complaint is about" ;;
esac
case "$ONLY" in both|all|debian)
	host_case debian:trixie-slim 44-host-debian.sh "glibc host: the regression case" ;;
esac
case "$ONLY" in all|ubuntu1404)
	host_case ubuntu:14.04 46-host-ubuntu.sh "pre-glvnd glibc: ubuntu:14.04 -- glibc 2.19, Mesa 10.1" ;;
esac
case "$ONLY" in all|ubuntu1604)
	host_case ubuntu:16.04 46-host-ubuntu.sh "pre-glvnd glibc: ubuntu:16.04 -- glibc 2.23, Mesa 18.0.5" ;;
esac

# Not a host, a different APPIMAGE: self-contained, its own Mesa, its own
# vendor libraries. It is what found the shim preferring a host vendor library
# over the bundle's own.
case "$ONLY" in all|gtk4)
	fetch_verified "$GTK4_URL" "$WORK/gtk4-demo.AppImage" "$GTK4_SHA" "gtk4-demo.AppImage ($ARCH)"
	if [ ! -d "$WORK/gtk4x/AppDir" ]; then
		in_container debian:trixie-slim 48-extract-gtk4.sh --privileged ||
			die "gtk4 extraction failed"
	fi
	say ""
	warn "######## a real application: gtk4-demo on musl Alpine ########"
	# Mounted as its own root, not as a subdirectory of the shared work tree,
	# so nothing can write one AppDir's files into the other's.
	in_container alpine:3.22 47-gtk4.sh -v "$WORK/gtk4x:/g" || fail=$((fail + 1))
	;;
esac

say ""
if [ "$fail" = 0 ]; then say "ALL PREDICTIONS HELD"; exit 0; fi
warn "SOME PREDICTIONS DID NOT HOLD -- investigate, this is a finding"
exit 1
