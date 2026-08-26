#!/bin/sh
# The end-to-end proof: a real AppImage using a real HOST graphics driver on a
# host whose libc is not the AppImage's.
#
# run-evidence.sh measures the mechanism in isolation. This measures the thing
# users actually complain about, on real software, across four host classes and
# a second AppImage:
#
#   debian:bullseye-slim  builds the artefacts on the glibc 2.31 FLOOR
#   alpine:3.22           musl host, the case the complaint is about
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
	alpine|debian|ubuntu1404|ubuntu1604|gtk4|gtk4hd|both|all) ;;
	*) die "--only must be alpine, debian, ubuntu1404, ubuntu1604, gtk4, gtk4hd, both or all" ;;
esac

# ---------------------------------------------------- the pinned downloads --
# One sha256 PER ARCHITECTURE, each computed from the asset itself. Copying a
# number out of a document is how a pin stops being a pin.
#
# ⛔ TWO REPOSITORIES, AND THE SECOND ONE IS NOT AN OVERSIGHT.
# pkgforge-dev/Anylinux-AppImages is the upstream. Samueru-sama's is a fork of
# it. gtk4-demo is taken from the upstream, where it belongs.
#
# ⚠ The demo AppImage cannot be. `vkcube+glxgears-host-drivers-demo-*` is
# published ONLY by the fork: the string "host-drivers" appears zero times in
# the upstream's code, and the upstream's demo release does not carry that
# asset. Its `vkcube+glxgears-demo-*` is the build that BUNDLES its drivers,
# which is the opposite of the case this whole suite exists to measure. So the
# fork is a real dependency for exactly one file, for a reason, and moving it
# would change what is being tested rather than where it comes from.
#
# ⛔ NEITHER TAG IS IMMUTABLE. Both repositories publish exactly one release
# and its tag is `demo`, so there is no version to pin to instead. Re-pinning
# is therefore a maintained act rather than a failure, and docs/report/09-the-second-boundary.md 9.15
# is the policy. The refusal in suite-lib.sh says which of the pin, the bytes
# and the published asset disagreed, so a re-pin is a decision and not a shrug.
ARCH=$(asset_suffix)
UPSTREAM_REPO=pkgforge-dev/Anylinux-AppImages
FORK_REPO=Samueru-sama/Anylinux-AppImages
TAG=demo
DEMO_ASSET="vkcube+glxgears-host-drivers-demo-$ARCH.AppImage"
GTK4_ASSET="gtk4-demo-$ARCH.AppImage"
GTK4HD_ASSET="gtk4-demo-host-drivers-$ARCH.AppImage"
case "$ARCH" in
	x86_64)
		DEMO_SHA=d77a01ebacb739392ca8c39f879dc5bc626283b0c01bd9dc12eecbea92dd34c1
		GTK4_SHA=413243c9ecbaaafe40636afd06e0c3d558b8cc928ed20b9ec55a6e0f09b5d8b4
		GTK4HD_SHA=b8ab47805c8fe9c7378a9d0b5b11e19c796a09c3f2a7b6c993968530bd5c10cd ;;
	aarch64)
		DEMO_SHA=9aeb38f7f2834c0cfc85117b032b51b08108f074304711edaa54a5c04e3caedb
		GTK4_SHA=e03ef26456fc0f3cd5c056e8bbaeab1cfcb0ba208e6f7c9ac88770775b1e3689
		GTK4HD_SHA=a5f17eca51e1c3b516191ac44a765308ddd9cba2ae5c3b9f4fadee2cfc114d9a ;;
esac
DEMO_URL="https://github.com/$FORK_REPO/releases/download/$TAG/$DEMO_ASSET"
GTK4_URL="https://github.com/$UPSTREAM_REPO/releases/download/$TAG/$GTK4_ASSET"
# The host-drivers gtk4 demo lives on the fork, where every "host-drivers"
# asset does; upstream's gtk4-demo is the self-contained build.
GTK4HD_URL="https://github.com/$FORK_REPO/releases/download/$TAG/$GTK4HD_ASSET"

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

fetch_verified "$DEMO_URL" "$WORK/demo.AppImage" "$DEMO_SHA" "demo.AppImage ($ARCH)" "$FORK_REPO" "$TAG" "$DEMO_ASSET"

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
	fetch_verified "$GTK4_URL" "$WORK/gtk4-demo.AppImage" "$GTK4_SHA" "gtk4-demo.AppImage ($ARCH)" "$UPSTREAM_REPO" "$TAG" "$GTK4_ASSET"
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

# The same application in the OTHER shape: a host-drivers gtk4 demo, bundling
# the glvnd dispatchers and no Mesa. On a classic host gles-fwd has no
# libGLESv2.so.2 to forward to and must resolve GLES through the host EGL's
# eglGetProcAddress; this is the case report/10 said was measured-but-not-repaired.
case "$ONLY" in all|gtk4hd)
	fetch_verified "$GTK4HD_URL" "$WORK/gtk4-demo-host-drivers.AppImage" "$GTK4HD_SHA" "gtk4-demo-host-drivers.AppImage ($ARCH)" "$FORK_REPO" "$TAG" "$GTK4HD_ASSET"
	if [ ! -d "$WORK/gtk4hd/AppDir" ]; then
		in_container debian:trixie-slim 49-extract-gtk4-host-drivers.sh --privileged ||
			die "gtk4 host-drivers extraction failed"
	fi
	say ""
	warn "######## a real application, host-drivers shape: gtk4-demo on musl Alpine ########"
	in_container alpine:3.22 50-gtk4-host-drivers.sh -v "$WORK/gtk4hd:/g" || fail=$((fail + 1))
	;;
esac

say ""
if [ "$fail" = 0 ]; then say "ALL PREDICTIONS HELD"; exit 0; fi
warn "SOME PREDICTIONS DID NOT HOLD -- investigate, this is a finding"
exit 1
