#!/bin/sh
# Extract the demo AppImage. Done in a container because the payload is DwarFS
# and --appimage-extract runs the AppImage's own ELF runtime.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends file >/dev/null 2>&1
cd /w
rm -rf AppDir squashfs-root
chmod +x demo.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ./demo.AppImage --appimage-extract >/dev/null 2>&1 || true
[ -d squashfs-root ] && mv squashfs-root AppDir
[ -d AppDir ] || { echo "extraction produced no AppDir"; exit 1; }
# Keep upstream's shim beside ours so the A/B can switch between them.
cp AppDir/lib/foreign-dlopen.so AppDir/lib/foreign-dlopen.upstream.so
# And the shipped .preload, for the same reason: the OpenGL cases rewrite it to
# add gl-fwd.so, and a run that started from a rewritten one would be measuring
# the shim in every case including the ones whose whole point is its absence.
# An AppImage without one is not an error here -- write an empty baseline, so
# the cases that need "no shims" still have something to restore.
if [ -f AppDir/.preload ]; then
    cp AppDir/.preload AppDir/.preload.shipped
else
    echo "AppDir has no .preload; using an empty one as the restore baseline"
    : > AppDir/.preload.shipped
fi

# The bundled glibc version, out of libc's own banner. grep -a rather than
# `strings`, which is in binutils and is not installed here: the version this
# whole report is written against printed as an empty string for as long as
# that went unnoticed, which is the quietest possible way to be wrong.
BUNDLED=$(grep -ao 'release version [0-9.]*' AppDir/lib/libc.so.6 2>/dev/null |
          head -1 | awk '{print $3}' | sed 's/\.$//')
echo "AppDir: $(ls AppDir/lib | wc -l) libraries, bundled glibc ${BUNDLED:-UNREADABLE}"
[ -n "$BUNDLED" ] || echo "  warning: could not read the bundled glibc version from libc.so.6"
