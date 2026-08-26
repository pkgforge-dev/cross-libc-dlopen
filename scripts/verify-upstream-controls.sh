#!/bin/sh
# Did the rename turn a control into a silent pass?
#
# ⛔ THE PROBLEM THIS EXISTS FOR. E30, E37a and E43a drive UPSTREAM's binary --
# the shim shipped inside the demo AppImage -- not this project's. Upstream only
# understands the old ANYLINUX_* variable names. If the harness stops sending
# them, upstream runs with the feature OFF.
#
# ⚠ And that does not produce a failure. E30 predicts NO-DEVICES; upstream with
# the feature off ALSO reports NO-DEVICES. The case goes green having measured
# nothing at all.
#
# ⭐ So the check is not whether the case passes. It is whether upstream's own
# debug lines appear. This runs both arms and prints the counts.
#
#   sh scripts/verify-upstream-controls.sh
#
# Needs the extracted AppDir and the floor build, which
# scripts/run-appimage.sh produces in .tmp.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname -- "$HERE")
WORK=${CLD_WORK:-$ROOT/.tmp}
. "$HERE/suite-lib.sh"

[ -d "$WORK/AppDir" ] || die "no $WORK/AppDir; run scripts/run-appimage.sh first"
[ -f "$WORK/build/vkprobe" ] || die "no $WORK/build/vkprobe; run scripts/run-appimage.sh first"

engine=$(resolve_engine)
say "engine: $engine"
"$engine" run --rm \
	-v "$WORK:/w" \
	-v "$HERE:/s:ro" \
	alpine:3.22 sh /s/_upstream-controls-inner.sh
