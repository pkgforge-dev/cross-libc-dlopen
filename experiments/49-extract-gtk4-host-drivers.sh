#!/bin/sh
# Extract the gtk4-demo HOST-DRIVERS AppImage, into its own directory.
#
# 48-extract-gtk4.sh extracts the SELF-CONTAINED gtk4 demo: it bundles its own
# Mesa and its own vendor library. This is the same application in the other
# shape: built as a host-drivers AppImage, bundling the glvnd dispatchers and no
# Mesa, so on a classic host it has nothing to dispatch to. That is the shape
# 50-gtk4-host-drivers.sh measures, and the case report/10 says was "measured,
# not repaired".
#
# Separate from both 41-extract.sh and 48-extract-gtk4.sh on purpose: the three
# AppDirs are different shapes, and mixing them is not a hypothetical. An
# earlier attempt here shared a working directory and ended with one AppImage's
# binaries inside another's tree, which took a suite run and a wrong diagnosis
# to notice.
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends file >/dev/null 2>&1
cd /w
rm -rf gtk4hd
mkdir -p gtk4hd
cd gtk4hd
cp /w/gtk4-demo-host-drivers.AppImage .
chmod +x gtk4-demo-host-drivers.AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ./gtk4-demo-host-drivers.AppImage --appimage-extract >/dev/null 2>&1 || true
rm -f gtk4-demo-host-drivers.AppImage
[ -d squashfs-root ] && mv squashfs-root AppDir
[ -d AppDir ] || { echo "extraction produced no AppDir"; exit 1; }
# The shipped .preload already names the forwarding shims (a host-drivers
# AppImage is built to use host drivers), so unlike 48-extract-gtk4.sh it is
# NOT the no-shim baseline. It is kept as the record; the no-shim control in
# 50-gtk4-host-drivers.sh writes its own.
if [ -f AppDir/.preload ]; then
    cp AppDir/.preload AppDir/.preload.shipped
else
    : > AppDir/.preload.shipped
fi
echo "gtk4 host-drivers AppDir: $(ls AppDir/lib | wc -l) libraries, $(ls AppDir/lib | grep -cE '^lib(GLX|EGL)_') bundled vendor libraries, $(ls AppDir/lib | grep -c '^libGLESv2.so.2$') bundled GLES dispatcher"
echo "shipped .preload:"
sed 's/^/    /' AppDir/.preload.shipped
