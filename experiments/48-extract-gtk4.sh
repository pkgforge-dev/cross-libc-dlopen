#!/bin/sh
# Extract the gtk4 demo AppImage, into its OWN directory.
#
# Separate from 41-extract.sh and separate from .tmp/AppDir on purpose: the two
# AppDirs are different shapes, since one bundles a dispatcher and no Mesa and the
# other bundles all of Mesa, and mixing them is not a hypothetical. An
# earlier attempt here shared the working directory and ended with vkcube's
# binaries inside the gtk4 tree and gtk4's inside the demo AppDir, which took a
# suite run and a wrong diagnosis to notice.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends file >/dev/null 2>&1
cd /w
rm -rf gtk4x
mkdir -p gtk4x
cd gtk4x
cp /w/gtk4-demo.AppImage .
chmod +x gtk4-demo.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ./gtk4-demo.AppImage --appimage-extract >/dev/null 2>&1 || true
rm -f gtk4-demo.AppImage
[ -d squashfs-root ] && mv squashfs-root AppDir
[ -d AppDir ] || { echo "extraction produced no AppDir"; exit 1; }
# The shipped .preload is the restore baseline: 47-gtk4.sh appends the shims to
# it and must be able to get back to a run with none.
if [ -f AppDir/.preload ]; then
    cp AppDir/.preload AppDir/.preload.shipped
else
    : > AppDir/.preload.shipped
fi
echo "gtk4 AppDir: $(ls AppDir/lib | wc -l) libraries, $(ls AppDir/lib | grep -cE '^lib(GLX|EGL)_') bundled vendor libraries"
