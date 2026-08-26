#!/bin/sh
# A real application, the third dispatcher, and the HOST-DRIVERS shape.
#
# 47-gtk4.sh measures the SELF-CONTAINED gtk4 demo, which bundles its own Mesa
# and its own vendor library, so gles-fwd forwards to the BUNDLED dispatcher
# because the bundle can stand on its own. This is the same application built
# the other way: a host-drivers AppImage, glvnd dispatchers and no Mesa. On a
# classic host there is no libGLESv2.so.2 at all (Alpine folds GLES into
# libEGL.so.1, reachable only through eglGetProcAddress) and no glvnd vendor,
# so gles-fwd's target selection fell through to the bundled dispatcher, whose
# GLES entry points are no-ops without a vendor behind them. GTK4's renderer is
# GLES, so it segfaulted. This is the case docs/report/10-measured-versus-assumed.md
# recorded as measured-but-not-repaired, and it is why GLFWD_ALT_SONAME exists.
#
#   /g/AppDir   the extracted gtk4-demo-host-drivers AppImage
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

# Deliberately NOT mesa-gles. Alpine's mesa-gles ships a standalone
# libGLESv2.so.2, and with it present gles-fwd's primary SONAME lookup finds a
# host library and the ALT (host-EGL) path is never reached. The case this
# stage exists for is the host that has EGL but no libGLESv2.so.2 at all, which
# is what mesa-egl alone provides.
apk add --no-cache mesa-gl mesa-dri-gallium mesa-egl \
                   xvfb xvfb-run procps >/dev/null 2>&1

# GTK4 wants a session bus, and without a machine-id it does not fail politely:
# it segfaults, with no AppImage and no shim involved. Give it one, in the
# throwaway container, or every case below measures dbus.
if [ ! -s /etc/machine-id ]; then
    dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > /etc/machine-id
    mkdir -p /var/lib/dbus && cp /etc/machine-id /var/lib/dbus/machine-id
fi

echo "================================================================"
echo " a real application, host-drivers shape: gtk4-demo on musl Alpine"
# An empty version here is the quietest possible way to be wrong. It happened
# once already, to the number this whole report is written against, so say
# UNREADABLE rather than printing nothing after the word "glibc".
GLIBCV=$(grep -ao 'release version [0-9.]*' "$LP/libc.so.6" 2>/dev/null |
         head -1 | awk '{print $3}' | sed 's/\.$//')
echo "   AppDir: $(ls "$LP" | wc -l) libraries, bundled glibc ${GLIBCV:-UNREADABLE}"
echo "   bundled vendor libraries: $(ls "$LP" | grep -cE '^lib(GLX|EGL)_')  bundled GLES dispatcher: $(ls "$LP" | grep -c '^libGLESv2.so.2$')"
echo "================================================================"

if [ ! -f "$A/.preload.shipped" ]; then
    echo "  FATAL: no $A/.preload.shipped -- extraction did not run"
    exit 2
fi
# The shipped AppDir carries its own copies of the forwarding shims; replace
# them with the ones built on the floor so the shim under test is this
# repository's, not the AppImage's.
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

# E91a: the control. With every preload from this project removed the AppImage
#        still runs, because GTK4 falls back to its Cairo renderer when there
#        is no GL at all. It must survive, or a shimmed run that dies would be
#        measuring GTK4 and not the shim. It must also call NO GLES entry point,
#        or "renders through GLES" below is not the shim's doing.
grep -vxE 'cross-libc-dlopen\.so|foreign-dlopen\.so|gl-fwd\.so|egl-fwd\.so|gles-fwd\.so' \
    "$A/.preload.shipped" > "$A/.preload" || true
gtk; rc=$?
[ "$rc" = 143 ] && r=1 || r=0
verdict E91a "$r" "no shims: rc=$rc (143 = still running when the timeout ended), $(called gles-fwd.so) GLES entry points"

# E91: as shipped, with the three forwarding shims in front. This is the case
#       that was FAILING: gles-fwd found no host libGLESv2.so.2 and no vendor,
#       forwarded to the bundled dispatcher, and GTK4's GLES renderer died.
cp "$A/.preload.shipped" "$A/.preload"
gtk CROSS_LIBC_DLOPEN_GL_TRACE=1; rc=$?
[ "$rc" = 143 ] && r=1 || r=0
verdict E91 "$r" "with gl+egl+gles shims: rc=$rc (segfaulted before the host-EGL lookup)"

# E92: gles-fwd chose the HOST EGL, not the bundled dispatcher. The host has no
#       libGLESv2.so.2, so "the bundled dispatcher" is a no-op here and this is
#       the whole repair.
if grep -q 'host EGL library' /tmp/gtk.out; then
    verdict E92 1 "gles-fwd target: the host EGL library (classic Mesa; GLES resolved through eglGetProcAddress)"
else
    verdict E92 0 "gles-fwd did not choose the host EGL: $(grep -m1 'target ' /tmp/gtk.out | cut -c1-70)"
fi

# E93: the whole table resolves through eglGetProcAddress, none absent. A shim
#       that resolves 200 of 358 hands GTK4 158 silent zeros.
got=$(grep -m1 -oE "[0-9]+ of 358 entry points resolved" /tmp/gtk.out | cut -d' ' -f1)
[ "${got:-0}" = 358 ] && r=1 || r=0
verdict E93 "$r" "gles-fwd: ${got:-0} of 358 entry points resolved (0 absent)"

# E94: GTK4 actually rendered, not just probed. The bound is 10 for the same
#       reason as E83: one call is a process that probed and stopped; a real
#       render is far above it.
ngles=$(called gles-fwd.so)
[ "$ngles" -ge 10 ] && r=1 || r=0
verdict E94 "$r" "gtk4-demo called $ngles GLES entry points -- GLES resolves through the host EGL"

cp "$A/.preload.shipped" "$A/.preload"
rm -f "$LP/gl-fwd.so" "$LP/egl-fwd.so" "$LP/gles-fwd.so"

echo
echo "================================================================"
echo " predictions matched: $PASS   mismatched: $FAIL   skipped: $SKIP"
echo "================================================================"
[ "$FAIL" -eq 0 ]
