#!/bin/sh
# Stage 2 -- runs in Debian trixie (glibc 2.41). Produces:
#   libnew.so  : needs GENUINELY NEW symbols (arc4random 2.36, strlcpy 2.38)
#   libthr.so  : needs a RE-HOMED symbol (pthread_create@GLIBC_2.34, moved into libc at 2.34)
#   newglibc/  : the newer runtime, for the "load a second libc" experiment
set -eu
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gcc binutils patchelf >/dev/null 2>&1
cd /work

# Drop the musl libc dependency from the Alpine probe -- this is precisely what
# cross-libc-dlopen.c does today (it refuses to let a second libc into the process).
cp libprobe.so libprobe_nomusl.so
patchelf --remove-needed libc.musl-x86_64.so.1 libprobe_nomusl.so

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
for f in libc.so.6 libm.so.6 ld-linux-x86-64.so.2; do
    cp -L "/lib/x86_64-linux-gnu/$f" newglibc/ 2>/dev/null || cp -L "/lib64/$f" newglibc/
done

# hostrt/ = the COMPLETE matched runtime set. E11 shows a mixed set segfaults, so an
# exec-time switch is only safe when every member comes from the same glibc.
# "Complete" has to mean every member Design R checks for (libutil and libanl
# included), or the completeness test refuses for the wrong reason.
mkdir -p hostrt
for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 \
         libanl.so.1 libresolv.so.2 ld-linux-x86-64.so.2; do
    cp -L "/lib/x86_64-linux-gnu/$f" hostrt/ 2>/dev/null || cp -L "/lib64/$f" hostrt/ 2>/dev/null || true
done

echo "== stage 2: built on glibc $(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$') =="
echo -n "   libnew.so needs: "; readelf -VW libnew.so | grep -oE 'GLIBC_[0-9.]+' | sort -u | tr '\n' ' '; echo
echo -n "   libthr.so needs: "; readelf -VW libthr.so | grep -oE 'GLIBC_[0-9.]+' | sort -u | tr '\n' ' '; echo
