#!/bin/sh
# Extract the demo AppImage. Done in a container because the payload is DwarFS
# and --appimage-extract runs the AppImage's own ELF runtime.
#
# ⛔ IT ALSO PINS THE APPDIR'S SHAPE, and that is not tidiness. The sha256 pin
# says the bytes are the ones somebody reviewed. It says nothing about the
# LAYOUT inside them, and 40-appimage.sh's whole A/B is one cp into one path.
# Upstream rebuilt this AppImage and the layout moved under it, twice over.
# docs/REPORT.md 9.17 has both, measured.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends file >/dev/null 2>&1
cd /w
rm -rf AppDir squashfs-root
chmod +x demo.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ./demo.AppImage --appimage-extract >/dev/null 2>&1 || true
[ -d squashfs-root ] && mv squashfs-root AppDir
[ -d AppDir ] || { echo "extraction produced no AppDir"; exit 1; }

# ------------------------------------------------ 1. the dispatcher slot ----
# The one file the A/B replaces. ⚠ Upstream RENAMED it: builds up to and
# including sha256 712766f8 shipped lib/foreign-dlopen.so, and the build
# pinned now ships lib/cross-libc-dlopen.so instead. Accept either BY NAME and
# print which was found. Guessing is worse than refusing here, because a wrong
# guess makes every case below measure an AppDir nobody patched.
SLOT=''
for cand in cross-libc-dlopen.so foreign-dlopen.so; do
    [ -f "AppDir/lib/$cand" ] && { SLOT=$cand; break; }
done
if [ -z "$SLOT" ]; then
    echo "no dispatcher slot in AppDir/lib."
    echo "  looked for: cross-libc-dlopen.so, foreign-dlopen.so"
    echo "  what is there:"
    ls AppDir/lib | sed 's/^/    /'
    exit 1
fi
printf '%s\n' "$SLOT" > AppDir/.cld-slot
echo "dispatcher slot: lib/$SLOT"
# Keep the shipped one beside ours so the A/B can switch between them.
cp "AppDir/lib/$SLOT" "AppDir/lib/$SLOT.upstream.so"

# --------------------------------------------------------- 2. the preload ---
# ⛔ TWO FILES, AND THE DIFFERENCE BETWEEN THEM IS THE POINT.
#
#   .preload.shipped   what the AppImage actually ships, byte for byte. A
#                      record, never restored from.
#   .preload.baseline  the same list with THIS PROJECT'S OWN forwarding shims
#                      removed. What the cases restore from.
#
# ⚠ Measured, and it is why the second file exists. The pinned build now names
# gl-fwd.so, egl-fwd.so and gles-fwd.so in its own .preload: upstream adopted
# them. Section J restores the baseline and then APPENDS the one shim under
# test, so with them already present every case whose whole point is the
# shim's ABSENCE would have run with upstream's copy of it, appended a
# duplicate line, and passed. Nothing would have reported anything.
#
# ⭐ What is removed is printed, on every run. A suite that edits the artefact
# under test and does not say so is worse than one that refuses.
if [ -f AppDir/.preload ]; then
    cp AppDir/.preload AppDir/.preload.shipped
else
    echo "AppDir has no .preload; using an empty one as the record"
    : > AppDir/.preload.shipped
fi
echo "shipped .preload:"
sed 's/^/    /' AppDir/.preload.shipped
grep -vxE 'gl-fwd\.so|egl-fwd\.so|gles-fwd\.so' AppDir/.preload.shipped \
    > AppDir/.preload.baseline || true
removed=$(grep -xE 'gl-fwd\.so|egl-fwd\.so|gles-fwd\.so' AppDir/.preload.shipped | tr '\n' ' ' || true)
if [ -n "$removed" ]; then
    echo "  ⚠ removed from the restore baseline: $removed"
    echo "    They are this project's own forwarding shims and section J adds"
    echo "    back the one under test. Leaving them in makes the absence cases"
    echo "    measure their presence. docs/REPORT.md 9.17."
else
    echo "  baseline is the shipped list unchanged: it names no forwarding shim"
fi

# --------------------------------------------------- 3. the bundled glibc ---
# Out of libc's own banner. grep -a rather than `strings`, which is in binutils
# and is not installed here: the version this whole report is written against
# printed as an empty string for as long as that went unnoticed, which is the
# quietest possible way to be wrong.
BUNDLED=$(grep -ao 'release version [0-9.]*' AppDir/lib/libc.so.6 2>/dev/null |
          head -1 | awk '{print $3}' | sed 's/\.$//')
echo "AppDir: $(ls AppDir/lib | wc -l) libraries, bundled glibc ${BUNDLED:-UNREADABLE}"
[ -n "$BUNDLED" ] || echo "  warning: could not read the bundled glibc version from libc.so.6"
