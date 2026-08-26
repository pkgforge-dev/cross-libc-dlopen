#!/bin/sh
# A REAL application, and the third dispatcher.
#
# Everything in 40-appimage.sh runs against the host-drivers demo AppImage:
# glxgears, vkcube, and two probes written for this repository. That AppDir
# bundles a dispatcher and no Mesa, which is one of the two shapes an AppImage
# comes in and not the common one. This is the other shape: a SELF-CONTAINED
# AppImage, 272 libraries, its own Mesa, its own libEGL_mesa.so.0, running a
# real GTK4 application on musl Alpine.
#
# It is here because it found a bug that four synthetic cases and two hosts did
# not. gl-fwd asked only whether the HOST had a vendor library; on Alpine the
# answer is no, so the shim forwarded a bundled GTK4 stack onto Alpine's Mesa,
# two Mesas ended up in one process, and gtk4-demo died with SIGFPE while the
# same AppImage with no shim ran fine. E80 is that, from both sides.
#
# And it is what made the GLES shim possible at all: the generator's one rule
# is that the export list comes out of the object being replaced, the
# host-drivers demo bundles no GLES, so until an AppDir that bundles
# libGLESv2.so.2 turned up there was nothing to read a table from.
#
#   /g/AppDir   the extracted gtk4-demo AppImage
#   /w/build    the shims, built on the glibc floor
set -u

A=/g/AppDir
LP="$A/lib"
PASS=0; FAIL=0; SKIP=0
XA='-screen 0 1024x768x24 +extension GLX +extension RANDR +render'
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR"

verdict() {                    # verdict <id> <0|1 ok> <text>
    if [ "$2" = 1 ]; then PASS=$((PASS+1)); v=MATCH; else FAIL=$((FAIL+1)); v=MISMATCH; fi
    printf '  %-6s %-8s %s\n' "$1" "$v" "$3"
}
skip() { SKIP=$((SKIP+1)); printf '  %-6s %-8s %s\n' "$1" "SKIPPED" "$2"; }

apk add --no-cache mesa-gl mesa-dri-gallium mesa-egl mesa-gles \
                   xvfb xvfb-run procps >/dev/null 2>&1

# GTK4 wants a session bus, and without a machine-id it does not fail politely:
# it segfaults, with no AppImage and no shim involved. Give it one, in the
# throwaway container, or every case below measures dbus.
if [ ! -s /etc/machine-id ]; then
    dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > /etc/machine-id
    mkdir -p /var/lib/dbus && cp /etc/machine-id /var/lib/dbus/machine-id
fi

echo "================================================================"
echo " a real application: gtk4-demo on musl Alpine"
# An empty version here is the quietest possible way to be wrong. It happened
# once already, to the number this whole report is written against, so say
# UNREADABLE rather than printing nothing after the word "glibc".
GLIBCV=$(grep -ao 'release version [0-9.]*' "$LP/libc.so.6" 2>/dev/null |
         head -1 | awk '{print $3}' | sed 's/\.$//')
echo "   AppDir: $(ls "$LP" | wc -l) libraries, bundled glibc ${GLIBCV:-UNREADABLE}"
echo "   bundled vendor libraries: $(ls "$LP" | grep -cE '^lib(GLX|EGL)_')  bundled GLES: $(ls "$LP" | grep -c '^libGLESv2.so.2$')"
echo "================================================================"

if [ ! -f "$A/.preload.shipped" ]; then
    echo "  FATAL: no $A/.preload.shipped -- extraction did not run"
    exit 2
fi
for s in gl-fwd.so egl-fwd.so gles-fwd.so; do
    [ -f "/w/build/$s" ] || { echo "  FATAL: /w/build/$s missing"; exit 2; }
    cp "/w/build/$s" "$LP/$s"
done

# gtk4-demo opens a window and never exits, so the exit STATUS is the whole
# measurement: 143 is the SIGTERM that ends a run which survived the timeout,
# and anything else is a death. SIGTERM also means no destructor runs, which is
# why the per-name count comes from CROSS_LIBC_DLOPEN_GL_TRACE and not from the exit
# summary, because the summary is never printed for a program that is killed.
gtk() {                        # gtk <extra-env...>
    : > /tmp/gtk.out
    env "$@" APPDIR="$A" GSK_RENDERER=gl LIBGL_ALWAYS_SOFTWARE=1 \
        timeout -k 2 35 xvfb-run -a -s "$XA" "$A"/AppRun.sh gtk4-demo \
        > /tmp/gtk.out 2>&1 </dev/null
    grc=$?
    pkill -9 gtk4-demo 2>/dev/null; pkill -9 Xvfb 2>/dev/null
    rm -f /tmp/.X*-lock 2>/dev/null
    return $grc
}
called() { grep -cF "[$1] >> first call:" /tmp/gtk.out; }

# E80a: the control. The AppImage as it ships, no shims. It must survive, or
#       nothing below means anything: a shimmed run that also dies would be
#       measuring GTK4 and not the shim.
cp "$A/.preload.shipped" "$A/.preload"
gtk; rc=$?
[ "$rc" = 143 ] && r=1 || r=0
verdict E80a "$r" "as shipped, no shims: rc=$rc (143 = still running when the timeout ended)"

# E80: and with all three shims in front of its own bundled dispatchers. This
#      is the case that was FAILING: the shim asked only whether the host had a
#      vendor library, Alpine has none, and a bundled GTK4 was forwarded onto
#      Alpine's Mesa. Two Mesas in one process, SIGFPE (rc=136).
cp "$A/.preload.shipped" "$A/.preload"
printf 'gl-fwd.so\negl-fwd.so\ngles-fwd.so\n' >> "$A/.preload"
gtk CROSS_LIBC_DLOPEN_GL_TRACE=1; rc=$?
[ "$rc" = 143 ] && r=1 || r=0
verdict E80 "$r" "with gl+egl+gles shims: rc=$rc (was 136/SIGFPE before the bundle's own vendor was looked for)"

# E81: and it chose the BUNDLE, for the bundle's own reason. A self-contained
#      AppImage is the stack the application was built and tested against;
#      "the host has no vendor" is not a reason to take it away.
if grep -q 'the AppImage is self-contained' /tmp/gtk.out; then
    verdict E81 1 "target chosen: the bundled dispatcher, because the BUNDLE has its own vendor library"
else
    verdict E81 0 "the bundle has a vendor library and the shim did not choose it: $(grep -m1 'target ' /tmp/gtk.out | cut -c1-70)"
fi

# E82: all three tables resolve completely against the object they replace.
#      A shim that exports 358 entry points and resolves 200 of them is a shim
#      that hands the application 158 silent zeros.
for pair in 'gl-fwd.so 3470' 'egl-fwd.so 44' 'gles-fwd.so 358'; do
    set -- $pair
    got=$(grep -m1 -oE "[0-9]+ of $2 entry points resolved" /tmp/gtk.out | cut -d' ' -f1)
    [ "${got:-0}" = "$2" ] && r=1 || r=0
    verdict "E82${1%%-*}" "$r" "$1: ${got:-0} of $2 entry points resolved from the bundled dispatcher"
done

# E83: what a REAL application actually calls. This is the number B6 exists
#      for: before it, "3470 forwarded entry points" had been exercised by
#      glxgears (33 linked) and a probe written here (15 called).
#
#      Reported, never thresholded, except for one bound that IS a claim.
#      E80 passes on rc=143, which means "still running when the timeout ended"
#      and cannot by itself tell a window that rendered from a process that
#      started and hung. GTK4 renders through GLES, so the GLES count is what
#      distinguishes them. The bound is 10 rather than 1 for the same reason:
#      one call is what a process that got as far as probing and stopped would
#      produce. Measured here: 46. Deliberately far below that and far above
#      one, because a threshold set near the measurement is a threshold that
#      fails when somebody's GTK renders one frame fewer.
ngl=$(called gl-fwd.so); negl=$(called egl-fwd.so); ngles=$(called gles-fwd.so)
[ "$ngles" -ge 10 ] && r=1 || r=0
verdict E83 "$r" "gtk4-demo called $ngl GL, $negl EGL and $ngles GLES entry points -- GTK4's renderer is GLES, which is why a GLES shim is not optional"

cp "$A/.preload.shipped" "$A/.preload"
rm -f "$LP/gl-fwd.so" "$LP/egl-fwd.so" "$LP/gles-fwd.so"

echo
echo "================================================================"
echo " predictions matched: $PASS   mismatched: $FAIL   skipped: $SKIP"
echo "================================================================"
[ "$FAIL" -eq 0 ]
