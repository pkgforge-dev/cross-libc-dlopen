#!/bin/sh
# Adding the three GL shims to an AppDir built by quick-sharun, before and
# after, on a musl host.
#
# ⭐ THIS DRIVES THE SUITE'S OWN STAGE rather than reimplementing it.
# experiments/47-gtk4.sh already performs exactly this comparison against the
# prebuilt gtk4-demo release asset, and it is a TEST: every line in it states a
# prediction the harness scores. A second copy here would drift from it, and
# the copy that drifted would be the one somebody read.
#
# WHAT IT SHOWS
#
#   E80a   the AppImage exactly as it ships, no shims
#   E80    the same AppImage with gl-fwd.so, egl-fwd.so and gles-fwd.so added
#   E81    which target the shims chose, and why
#   E82*   how many of each dispatcher's entry points resolved
#   E83    which entry points the application actually CALLED
#
# ⚠ WHAT IT FOUND, and it is the reason this example is worth reading: a
# self-contained AppImage that bundles its own vendor library must KEEP it.
# Forwarding to the host's because the host has none puts two Mesas in one
# process. E80 was SIGFPE before the bundle's own vendor was looked for
# first. E81 is the case that states the rule.
#
#   sh examples/appimage-gl-shims/run.sh
#
# Tens of minutes on a cold cache: it downloads a 30 MB AppImage, verifies its
# sha256 and extracts it inside a container.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

cat <<'INTRO'
=================================================================
 Adding gl-fwd.so, egl-fwd.so and gles-fwd.so to a real AppDir
=================================================================

  before : the AppImage as published, .preload untouched
  after  : the same AppImage, three shims added to .preload

The .preload file is SHARUN'S, not this project's -- this project's
interface is LD_PRELOAD, and .preload is one launcher's way of
populating it. Its ORDER does not matter: preload constructors run in
reverse of the list, which is why the shims ask for the loader rather
than depending on being listed after it.

INTRO

exec sh "$ROOT/scripts/run-appimage.sh" --only gtk4
