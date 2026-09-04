#!/bin/sh
# Stage 2, running in Debian trixie (glibc 2.41). Produces:
#   libnew.so  : needs GENUINELY NEW symbols (arc4random 2.36, strlcpy 2.38)
#   libthr.so  : needs a RE-HOMED symbol (pthread_create@GLIBC_2.34, moved into libc at 2.34)
#   newglibc/  : the newer runtime, for the "load a second libc" experiment
set -eu
# ⚠ Same bootstrap rule as stage 3: the apt output is kept, and a toolchain
# that did not install fails the stage naming itself, because a silent
# failure here hands stage 3 no libraries and the evidence table then reports
# mismatches that name the cases instead of the cause. https and retries for
# the same reasons stage 3 gives.
sed -i 's|http://deb.debian.org|https://deb.debian.org|g' \
	/etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
apt-get update -qq -o Acquire::Retries=3 >/work/.apt2-update.log 2>&1 || true
apt-get install -y -qq -o Acquire::Retries=3 gcc binutils patchelf \
	>/work/.apt2-install.log 2>&1 || true
for _tool in gcc readelf; do
    command -v "$_tool" >/dev/null 2>&1 || {
        echo "STAGE 2 CANNOT RUN: $_tool did not install; the apt output follows" >&2
	sed 's/^/  update| /' /work/.apt2-update.log >&2
	sed 's/^/  install| /' /work/.apt2-install.log >&2
	exit 2
    }
done
cd /work

# ⚠ Three things in this stage carry the architecture: the loader name, the
# multiarch directory, and musl's soname. Hardcoded to x86-64 they made this
# stage die on aarch64 at `cp /lib64/libc.so.6`, and they would have made E1
# report MISMATCH, because its needle is "undefined symbol: atexit", so a probe that
# still NEEDs musl fails for a different reason and does not match.
#
# Derived from uname -m, which is the mechanism already used for the asset
# suffix in scripts/suite-lib.sh. An architecture with no row here stops the
# stage rather than quietly proceeding under x86-64's names.
case "$(uname -m)" in
    x86_64)
        LDSO=ld-linux-x86-64.so.2 ; TRIPLET=x86_64-linux-gnu
        LIBDIR2=/lib64            ; MUSL_SO=libc.musl-x86_64.so.1 ;;
    aarch64)
        LDSO=ld-linux-aarch64.so.1; TRIPLET=aarch64-linux-gnu
        LIBDIR2=/lib              ; MUSL_SO=libc.musl-aarch64.so.1 ;;
    *)
        echo "stage 2: no loader, triplet and musl soname known for $(uname -m)" >&2
        exit 1 ;;
esac

# Drop the musl libc dependency from the Alpine probe. This is precisely what
# cross-libc-dlopen.c does today (it refuses to let a second libc into the process).
cp libprobe.so libprobe_nomusl.so
patchelf --remove-needed "$MUSL_SO" libprobe_nomusl.so

cat > newlib.c <<'CEOF'
#define _GNU_SOURCE
#include <string.h>
#include <stdlib.h>
static char buf[64];
int newlib_answer(void){
    strlcpy(buf, "hello", sizeof buf);       /* glibc 2.38 */
    return (int)(arc4random() % 1) + 99;     /* glibc 2.36 */
}
CEOF
gcc -shared -fPIC -O2 -Wl,-z,now newlib.c -o libnew.so

cat > thr.c <<'CEOF'
#include <pthread.h>
static void *w(void *a){ return a; }
int thr_answer(void){ pthread_t t; pthread_create(&t,0,w,0); pthread_join(t,0); return 77; }
CEOF
gcc -shared -fPIC -O2 -Wl,-z,now thr.c -o libthr.so

# newglibc/ = a PARTIAL runtime (libc+libm+ld.so): used to show in-process loading fails.
mkdir -p newglibc
for f in libc.so.6 libm.so.6 "$LDSO"; do
    cp -L "/lib/$TRIPLET/$f" newglibc/ 2>/dev/null || cp -L "$LIBDIR2/$f" newglibc/
done

# hostrt/ = the COMPLETE matched runtime set. E11 shows a mixed set segfaults, so an
# exec-time switch is only safe when every member comes from the same glibc.
# "Complete" has to mean every member Design R checks for (libutil and libanl
# included), or the completeness test refuses for the wrong reason.
mkdir -p hostrt
for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 \
         libanl.so.1 libresolv.so.2 "$LDSO"; do
    cp -L "/lib/$TRIPLET/$f" hostrt/ 2>/dev/null || cp -L "$LIBDIR2/$f" hostrt/ 2>/dev/null || true
done

echo "== stage 2: built on glibc $(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$') =="
echo -n "   libnew.so needs: "; readelf -VW libnew.so | grep -oE 'GLIBC_[0-9.]+' | sort -u | tr '\n' ' '; echo
echo -n "   libthr.so needs: "; readelf -VW libthr.so | grep -oE 'GLIBC_[0-9.]+' | sort -u | tr '\n' ' '; echo
