#!/bin/bash
# Stage 3 -- runs in Debian bullseye (glibc 2.31), standing in for "an AppImage that
# bundles an older glibc". Every experiment states its PREDICTION; the harness reports
# MATCH / MISMATCH against it. A MISMATCH is a finding, not a failure of the harness.
set -u
apt-get update -qq >/dev/null 2>&1
# The aarch64 cross toolchain and qemu-user are for section P, which RUNS the
# aarch64 trampolines rather than only assembling them. They are installed
# best-effort: if the host has no network for them the section SKIPS by name
# (section 7) rather than failing a suite whose other cases are unaffected.
#
# ⚠ Not on an aarch64 host, where section P builds with the native gcc and
# runs on the CPU. Installing an emulator for the architecture you are
# standing on is how E76 came to run under qemu on real aarch64 silicon.
apt-get install -y -qq gcc binutils python3 >/dev/null 2>&1
if [ "$(uname -m)" != aarch64 ]; then
    apt-get install -y -qq --no-install-recommends \
        gcc-aarch64-linux-gnu libc6-dev-arm64-cross qemu-user-static >/dev/null 2>&1
fi
cd /work

# ⚠ The same three architecture-carrying names stage 2 derives, derived the
# same way, because this stage is the MATCHER for what stage 2 emits: it runs
# /work/newglibc/<loader> and copies out of the multiarch directory. The two
# must agree, or the assertion is no longer the one that was written.
#
# CET is the fourth. -fcf-protection=full is x86-only, and on aarch64 gcc it
# is a hard error rather than a warning, so the four helper builds in sections
# M and N would not compile at all -- and a helper that does not build reports
# itself as "./tramp2: No such file or directory", which names the wrong thing
# entirely. It buys endbr64 on x86-64 and there is no endbr64 on aarch64, so
# dropping it there removes nothing that was being measured.
# ⚠ $CET is deliberately unquoted below: it is one word or none, and "" would
# hand gcc an empty argument.
case "$(uname -m)" in
    x86_64)
        LDSO=ld-linux-x86-64.so.2 ; TRIPLET=x86_64-linux-gnu
        LIBDIR2=/lib64            ; CET=-fcf-protection=full ;;
    aarch64)
        LDSO=ld-linux-aarch64.so.1; TRIPLET=aarch64-linux-gnu
        LIBDIR2=/lib              ; CET= ;;
    *)
        echo "stage 3: no loader and triplet known for $(uname -m)" >&2
        exit 1 ;;
esac

BASE_GLIBC=$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$')
PASS=0; FAIL=0

# ---------------------------------------------------------------- helpers
cat > strip_ver.py <<'PEOF'
# Neutralise DT_VERSYM/VERNEED/VERDEF/VERDEFNUM by retagging them to an unknown tag
# ld.so ignores -- exactly what cross-libc-dlopen.c does. All four must go together:
# a verdef without its versym segfaults ld.so.
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
phoff, = struct.unpack_from('<Q', d, 0x20)
phnum, = struct.unpack_from('<H', d, 0x38)
for i in range(phnum):
    t, _, off, _, _, fsz, _, _ = struct.unpack_from('<IIQQQQQQ', d, phoff + i*56)
    if t != 2:            # PT_DYNAMIC
        continue
    for j in range(fsz // 16):
        tag, = struct.unpack_from('<q', d, off + j*16)
        if tag == 0:
            break
        if tag in (0x6ffffff0, 0x6ffffffe, 0x6ffffffc, 0x6ffffffd):
            struct.pack_into('<q', d, off + j*16, 0x414e594c)   # 'ANYL'
open(sys.argv[2], 'wb').write(d)
PEOF

cat > loader.c <<'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
/* argv[1]=library  argv[2]=symbol  argv[3]="m" for dlmopen(LM_ID_NEWLM) */
int main(int argc, char **argv) {
    void *h;
    if (argc > 3 && argv[3][0] == 'm') h = dlmopen(LM_ID_NEWLM, argv[1], RTLD_NOW);
    else                               h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("FAILED: %s\n", dlerror()); return 1; }
    int (*f)(void) = dlsym(h, argv[2]);
    if (!f) { printf("FAILED: no symbol %s\n", argv[2]); return 1; }
    printf("OK: %s()=%d\n", argv[2], f());
    return 0;
}
CEOF
gcc -O2 loader.c -o loader     -ldl
gcc -O2 loader.c -o loader_pth -ldl -Wl,--no-as-needed -lpthread

cat > shim_atexit.c <<'CEOF'
/* musl exports atexit dynamically; glibc keeps it in the static libc_nonshared.a,
   so it is absent from libc.so.6 and unresolvable for a musl-built guest. */
#include <stddef.h>
extern int __cxa_atexit(void (*)(void *), void *, void *);
__attribute__((visibility("default")))
int atexit(void (*fn)(void)) { return __cxa_atexit((void (*)(void *))fn, NULL, NULL); }
CEOF
gcc -shared -fPIC -O2 shim_atexit.c -o shim_atexit.so

cat > shim_forward.c <<'CEOF'
/* Forward-compatibility shim: implements symbols that exist only in NEWER glibc,
   over the older glibc we are actually running on. Generatable from glibc's own
   symbol tables -- this hand-written sample covers the two the test needs. */
#define _GNU_SOURCE
#include <stddef.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#define VIS __attribute__((visibility("default")))
VIS size_t strlcpy(char *d, const char *s, size_t n) {
    size_t sl = strlen(s);
    if (n) { size_t c = sl < n - 1 ? sl : n - 1; memcpy(d, s, c); d[c] = 0; }
    return sl;
}
VIS size_t strlcat(char *d, const char *s, size_t n) {
    size_t dl = strnlen(d, n);
    if (dl == n) return n + strlen(s);
    return dl + strlcpy(d + dl, s, n - dl);
}
VIS void arc4random_buf(void *b, size_t n) {
    while (n) { long r = syscall(SYS_getrandom, b, n, 0); if (r <= 0) break;
                b = (char *)b + r; n -= (size_t)r; }
}
VIS unsigned arc4random(void) { unsigned v = 0; arc4random_buf(&v, sizeof v); return v; }
VIS unsigned arc4random_uniform(unsigned u) { return u ? arc4random() % u : 0; }
CEOF
gcc -shared -fPIC -O2 shim_forward.c -o shim_forward.so

python3 strip_ver.py libprobe_nomusl.so libprobe_s.so 2>/dev/null || true
python3 strip_ver.py libnew.so  libnew_s.so
python3 strip_ver.py libthr.so  libthr_s.so

# ---------------------------------------------------------------- harness
#
# ⛔ T-13. A helper build whose stderr goes to /dev/null turns a compiler error
# into a cascade of cases reporting "No such file or directory", which names
# the wrong thing entirely. It cost a debugging cycle once when an include
# broke tgt-fwd.so, and it cost another when a moved Python module broke the
# shim generator: ten cases and two cases respectively, neither naming a cause.
#
# ⚠ The stderr is captured rather than shown, and printed ONLY when the
# command fails. A passing run is exactly as quiet as before, and no assertion
# changes: this runs after the build, and the cases still score themselves.
BERR=/work/.build-stderr
bfail() {                     # bfail <label>; always returns 1
    printf '  BUILD FAILED: %s\n' "$1"
    [ -s "$BERR" ] && sed 's/^/           | /' "$BERR"
    return 1
}

run() {                       # run <id> <expect: OK|FAIL> <expect-substring> <cmd...>
    local id="$1" want="$2" needle="$3"; shift 3
    local out rc
    out=$("$@" 2>&1); rc=$?
    local got="OK"; [ $rc -ne 0 ] && got="FAIL"
    local verdict="MISMATCH"
    if [ "$got" = "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
        verdict="MATCH"; PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
    printf '  %-6s %-4s predicted=%-4s  %s\n' "$id" "$verdict" "$want" "$(printf '%s' "$out" | head -1)"
    # ⛔ On a MISMATCH, the WHOLE captured output, not the first line of it.
    # A one-line summary of a failure names the symptom and hides the cause:
    # E16 reported "ok strlcpy short" for a probe that failed forty checks
    # later, and the cause was not in the line that was printed.
    # ⚠ This runs only after the case has already been scored, so it changes
    # no assertion. T-13 is the same shape applied to the helper builds.
    if [ "$verdict" = "MISMATCH" ]; then
        printf '%s\n' "$out" | sed 's/^/           | /'
        printf '           | (exit %s, wanted %s, needle: %s)\n' "$rc" "$want" "$needle"
    fi
}

echo "================================================================"
echo " Cross-libc dlopen evidence  --  base process glibc $BASE_GLIBC"
echo "================================================================"

echo
echo "-- A. musl host library into a glibc process ------------------"
run E1 FAIL "undefined symbol: atexit" \
    ./loader /work/libprobe_nomusl.so probe_answer
run E2 OK   "probe_answer()=42" \
    env LD_PRELOAD=/work/shim_atexit.so ./loader /work/libprobe_nomusl.so probe_answer

echo
echo "-- B. NEWER-glibc host library into an OLDER glibc process ----"
run E3 FAIL "GLIBC_2.38' not found" \
    ./loader /work/libnew.so newlib_answer
run E4 FAIL "undefined symbol: arc4random" \
    ./loader /work/libnew_s.so newlib_answer
run E5 OK   "newlib_answer()=99" \
    env LD_PRELOAD=/work/shim_forward.so ./loader /work/libnew_s.so newlib_answer

echo
echo "-- C. re-homed symbols (glibc 2.34 library consolidation) -----"
run E6 FAIL "undefined symbol: pthread_create" \
    ./loader /work/libthr_s.so thr_answer
run E7 OK   "thr_answer()=77" \
    ./loader_pth /work/libthr_s.so thr_answer

echo
echo "-- D. can a SECOND libc be loaded in-process? -----------------"
run E8 FAIL "GLIBC_2.35' not found" \
    ./loader /work/newglibc/libc.so.6 __libc_start_main
cp libnew.so libnew_rp.so
if command -v patchelf >/dev/null 2>&1; then patchelf --set-rpath /work/newglibc libnew_rp.so; fi
run E9 FAIL "GLIBC_2.35' not found" \
    ./loader /work/newglibc/libc.so.6 __libc_start_main m

echo
echo "-- E. exec-time whole-runtime switch: the answer for symbols we cannot predict"
printf '#include <stdio.h>\nint main(void){puts("hello from switched runtime");return 0;}\n' > h.c
gcc -O2 h.c -o h
run E10 OK "hello from switched runtime" \
    /work/newglibc/$LDSO --library-path /work/newglibc ./h

echo "  E11    (informational) mixing an OLD libdl with a NEW libc:"
/work/newglibc/$LDSO --library-path /work/newglibc:/lib/$TRIPLET \
    ./loader /work/libnew.so newlib_answer >/dev/null 2>&1
echo "         exit=$?  (139 = SIGSEGV: the runtime set must be switched WHOLE)"

# E12 answers "how do you guarantee forward compat for a symbol that does not exist yet?".
# You do not shim it. You run under the host's own runtime, so the symbol resolves natively.
# Note NO shim is preloaded here -- contrast with E5.
run E12 OK "newlib_answer()=99" \
    /work/hostrt/$LDSO --library-path /work/hostrt ./loader /work/libnew.so newlib_answer

echo
echo "-- F. library search path: --library-path vs /etc/ld.so.cache ---"
# Anylinux patches ld-linux.so to skip /etc/ld.so.cache (it segfaults on some hosts),
# so --library-path becomes the ONLY discovery mechanism. --inhibit-cache reproduces
# that patched loader exactly. /usr/local/lib is a real dir on every distro surveyed
# and is absent from sharun's hardcoded list -- so this is a live gap, not a hypothetical.
echo "int foo_answer(void){return 55;}" > foo.c
mkdir -p /usr/local/lib
gcc -shared -fPIC -Wl,-soname,libfoo.so.1 foo.c -o /usr/local/lib/libfoo.so.1
ldconfig
cat > byname.c <<'CEOF'
#include <stdio.h>
#include <dlfcn.h>
int main(void){ void *h = dlopen("libfoo.so.1", RTLD_NOW);
    if(!h){ printf("FAILED: %s\n", dlerror()); return 1; }
    int (*f)(void) = dlsym(h,"foo_answer"); printf("OK: %d\n", f?f():-1); return 0; }
CEOF
gcc -O2 byname.c -o byname -ldl
LD=$LIBDIR2/$LDSO
SHARUN_LIKE="/work:/usr/lib:/lib:/usr/lib64:/lib64:/usr/lib/$TRIPLET"   # no /usr/local/lib

run E13a OK   "OK: 55" $LD --library-path "$SHARUN_LIKE" ./byname
run E13b FAIL "cannot open shared object file" $LD --library-path "$SHARUN_LIKE" --inhibit-cache ./byname
run E13c OK   "OK: 55" $LD --library-path "/usr/local/lib:$SHARUN_LIKE" --inhibit-cache ./byname

# ===================================================================
#  G. THE FIX -- one case per change in ../src (one case per fix)
#
#  Everything above measures the problem. Everything below measures a
#  specific fix, and each one is written so it FAILS without that fix.
# ===================================================================
echo
echo "-- G. the fix ---------------------------------------------------"

if [ ! -f /repo/src/runtime-select.c ]; then
    echo "  E14..E20  SKIPPED - the repo is not mounted at /repo"
else
    # ---- Tier 0: the ELF rewriting, tested against the REAL implementation --
    # tests/elf-selftest.c #includes cross-libc-dlopen.c, so T0.4/T0.5/T0.7/T0.8
    # exercise the shipped predicates rather than a model of them.
    gcc -O2 -Wno-format-truncation /repo/tests/elf-selftest.c \
        -o elf-selftest -ldl 2>"$BERR" || bfail elf-selftest
    run E14 OK "ELF SELFTEST PASSED" ./elf-selftest /lib/$TRIPLET/libz.so.1

    # ---- Design B: the GENERATED shim ----
    # Generated here, in the container, for THIS process's glibc 2.31 floor --
    # so the test covers the generator, not a checked-in snapshot of its output.
    if command -v python3 >/dev/null 2>&1; then
        python3 /repo/tools/gen_forward_shim.py \
            --floor /repo/inventories/glibc-2.31.json \
            --target /repo/inventories/glibc-2.44.json \
            --out gen-shim.c --manifest gen-shim.json --quiet 2>"$BERR" || bfail gen-shim.c

        # E15: it compiles clean against the floor it claims to target.
        run E15 OK "compiled" sh -c \
            'gcc -shared -fPIC -O2 -Wall -Werror gen-shim.c -o gen-shim.so 2>&1 && echo compiled'

        # E16: and the implementations are CORRECT, not merely present --
        #      ~40 documented behaviours, on a glibc that really lacks them.
        gcc -O2 /repo/tests/shim-selftest.c -o shimtest \
            -L"$PWD" -l:gen-shim.so -Wl,-rpath,"$PWD" >"$BERR" 2>&1 || bfail shimtest
        run E16 OK "SHIM TEST PASSED" ./shimtest
    else
        echo "  E15    SKIPPED - no python3 in this image"
        echo "  E16    SKIPPED - depends on E15"
    fi

    # ---- Design R: the host-runtime selector ----
    gcc -O2 -Wno-format-truncation /repo/src/runtime-select.c \
        -o runtime-select -ldl 2>"$BERR" || bfail runtime-select

    # An AppDir bundling glibc 2.41 -- NEWER than this container's 2.31 host.
    rm -rf app_new && mkdir -p app_new/lib && cp -L /work/hostrt/* app_new/lib/ 2>/dev/null

    # E17: host OLDER than bundled -> keep bundled, and say why.
    run E17 OK "is not newer than bundled" \
        env APPDIR="$PWD/app_new" ./runtime-select --probe

    # An AppDir bundling this host's own 2.31: equal, so still bundled.
    # Bundle exactly the members hostrt stages, so "incomplete" can never be
    # the reason a later test refuses -- E20 has to fail for the RIGHT reason.
    rm -rf app_old && mkdir -p app_old/lib
    for f in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 \
             libutil.so.1 libanl.so.1 libresolv.so.2; do
        cp -L "/lib/$TRIPLET/$f" app_old/lib/ 2>/dev/null || true
    done
    cp -L "$LIBDIR2/$LDSO" app_old/lib/ 2>/dev/null || true
    run E18 OK "runtime      : bundled" env APPDIR="$PWD/app_old" ./runtime-select --probe

    # E19: the override is real. Forcing bundled must be honoured verbatim.
    run E19 OK "forced by the user" \
        env APPDIR="$PWD/app_old" CROSS_LIBC_DLOPEN_RUNTIME=bundled ./runtime-select --probe

    # E20: THE E11 GUARD, and the reason Design R is not just "pick the newer
    #      one". Hand the selector a MIXED set -- 2.41's ld.so and libc beside
    #      2.31's libdl and libpthread -- as if it were the host. E11 proved
    #      that combination segfaults on contact, so the only right answer is
    #      to refuse it. A selector that accepts it is worse than none.
    # Every member present -- so "incomplete" cannot be the reason -- but
    # libdl/libpthread/librt/libutil come from the OLD glibc.
    rm -rf mixedhost && mkdir -p mixedhost
    cp -L /work/hostrt/* mixedhost/ 2>/dev/null
    for f in libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1; do
        cp -L "/lib/$TRIPLET/$f" mixedhost/ 2>/dev/null || true
    done
    run E20 OK "NOT internally consistent" \
        env APPDIR="$PWD/app_old" ./runtime-select --probe --host-dir "$PWD/mixedhost"

    # E21: the control for E20. The SAME newer glibc, unmixed, must be
    #      ACCEPTED -- otherwise E20 would pass by refusing everything, which
    #      is not a guard, it is a broken selector.
    rm -rf goodhost && mkdir -p goodhost && cp -L /work/hostrt/* goodhost/ 2>/dev/null
    run E21 OK "runtime      : host" \
        env APPDIR="$PWD/app_old" ./runtime-select --probe --host-dir "$PWD/goodhost"

    # ---- the build-time strict-environment option -------------------------
    #
    # APPDIR is a convention this project does not own: an AppImage runtime
    # exports it into every process it starts. It is kept by default for that
    # reason, and src/cld-env.h has the argument in full.
    #
    # ⭐ A consumer who wants ONE spelling and no interop can have it, and gets
    # it where the choice belongs: at build time, where whoever assembles the
    # bundle knows whether an AppImage runtime is in the picture. A library
    # cannot know that.
    #
    # ⛔ Two cases because one would not be a measurement. E87 alone would pass
    # if the strict build were simply broken and found no root under any name.
    gcc -O2 -DCLD_STRICT_ENV -Wall -Wextra -Wno-format-truncation -I/repo/src \
        /repo/src/runtime-select.c -o runtime-select-strict -ldl \
        2>"$BERR" || bfail runtime-select-strict

    # E87: the strict build IGNORES APPDIR. The needle is the appdir line and
    #      not the runtime line: "runtime : bundled" is also what a probe that
    #      found nothing reports, so it cannot tell the two apart.
    run E87 OK "appdir       : (unset)" \
        env APPDIR="$PWD/app_old" ./runtime-select-strict --probe

    # E88: and the same binary still works under this project's own name, so
    #      E87 is APPDIR being ignored rather than the build being inert.
    run E88 OK "appdir       : $PWD/app_old" \
        env CROSS_LIBC_DLOPEN_ROOT="$PWD/app_old" ./runtime-select-strict --probe

    # ---- H. the version-binding trap, and the forwarders that close it ----
    #
    # T3.2 was blamed on glibc-vs-musl ABI differences for a long time. It is
    # not that. Removing an object's version requirements is itself enough to
    # break it, on ONE libc, with no musl and no Vulkan anywhere in the process.
    echo
    echo "-- H. the version-binding trap ----------------------------------"

    gcc -shared -fPIC -O2 /repo/tests/verprobe.c -o verprobe.so -lpthread
    python3 strip_ver.py verprobe.so verprobe_stripped.so

    # ⚠ The trap E22 measures belongs to THIS libc, not to this project. It
    # needs pthread_cond_init exported at TWO symbol versions, an obsolete one
    # beside the current one. Measured on debian:bullseye-slim: x86-64's
    # libc.so.6 and libpthread.so.0 each carry pthread_cond_init@GLIBC_2.2.5
    # and @@GLIBC_2.3.2, and the aarch64 libc of the same release carries only
    # @@GLIBC_2.17. So on aarch64 there is no obsolete definition to bind to,
    # the stripped object returns 0, and E22 reported MISMATCH.
    condvar_versions=0
    for _l in "/lib/$TRIPLET/libpthread.so.0" "/lib/$TRIPLET/libc.so.6"; do
        [ -e "$_l" ] || continue
        _n=$(readelf -sW "$_l" 2>/dev/null |
             grep -oE 'pthread_cond_init@+GLIBC_[0-9.]+' | sort -u | wc -l)
        [ "$_n" -gt "$condvar_versions" ] && condvar_versions=$_n
    done

    # E22: THE BUG. Same file, same libc, only the version tags removed, and
    #      pthread_cond_init now returns EINVAL(22) instead of 0. Everything
    #      users have reported as "the driver loads but nothing works" is this
    #      number. If this ever reports 0 the trap is gone from this glibc and
    #      E23 is measuring nothing -- which is why both sides are asserted.
    if [ "$condvar_versions" -ge 2 ]; then
        run E22 OK "probe_cond_init()=22" ./loader /work/verprobe_stripped.so probe_cond_init
    else
        echo "  E22    SKIPPED - this libc exports pthread_cond_init at"
        echo "         $condvar_versions symbol version(s). The trap needs an obsolete"
        echo "         definition beside the current one, which x86-64 glibc"
        echo "         carries and this one does not."
    fi

    # E22b: the control. The very same object, unstripped, is fine -- so E22
    #       cannot be blamed on the probe, the compiler or this container.
    run E22b OK "probe_cond_init()=0" ./loader /work/verprobe.so probe_cond_init

    # E23: THE FIX. The stripped object again, with the preload merely present.
    #      CROSS_LIBC_DLOPEN is deliberately NOT set: no dlopen
    #      interception, no ELF rewriting, nothing but version-compat.c's
    #      unversioned definitions sitting in the global lookup scope.
    gcc -shared -fPIC -O2 -Wall -Wextra -Wno-format-truncation -I/repo/src \
        /repo/src/cross-libc-dlopen.c /repo/src/forward-shim.c /repo/src/version-compat.c \
        -o cross-libc-dlopen.so -ldl 2>"$BERR" || bfail cross-libc-dlopen.so
    # ⛔ E23 is skipped WITH E22, not left running. E22's comment above says
    # why: with no trap in this libc the stripped object already returns 0, so
    # E23 passes whether or not version-compat.c does anything at all. It was
    # reporting MATCH on the ARM runner while asserting nothing, which is the
    # shape this repository calls a silent pass.
    # ⚠ The build stays unconditional: cross-libc-dlopen.so is used by the
    # host-dependency cases further down, which do not need the trap.
    # ⛔ CROSS_LIBC_DLOPEN=0 is stated rather than left unset. The feature is
    # ON by default now, and this case measures version-compat.c's unversioned
    # definitions sitting in the global lookup scope with NO dlopen
    # interception in the process. Relying on unset to mean off would have
    # turned this into a different measurement the day the default changed,
    # silently, and it would still have printed 0.
    if [ "$condvar_versions" -ge 2 ]; then
        run E23 OK "probe_cond_init()=0" \
            env CROSS_LIBC_DLOPEN=0 LD_PRELOAD=/work/cross-libc-dlopen.so \
                ./loader /work/verprobe_stripped.so probe_cond_init
    else
        echo "  E23    SKIPPED - it can only measure the fix where E22's trap"
        echo "         exists; without it the unstripped answer is already 0."
    fi

    # ---- the deprecated ANYLINUX_* spellings, and that they are gone ------
    #
    # Every control here used to have a second spelling, read as a deprecated
    # alias so that a bundle built before the rename kept working. No such
    # bundle exists: this project has never published a release, so nothing
    # sets one, and carrying the aliases meant every control had two names and
    # one of them appeared in no document.
    #
    # ⛔ These two are a PAIR and neither means anything alone. E84 says the
    # debug control works, so E85's silence is the alias being gone rather than
    # the preload failing to load at all. E85 MISMATCHED before the aliases
    # were removed, which is what makes it a measurement.
    #
    # ⚠ E85 asserts an ABSENCE, and `run` can only assert that a string is
    # present, so the absence is turned into a word. Reading grep's status
    # inside the case is deliberate and is not the "exit code through a pipe"
    # trap: the pipeline IS the assertion here, not a check whose code is being
    # misread.
    #
    # ⚠ ANYLINUX_LIB_DEBUG is still set by experiments/40-appimage.sh and by
    # scripts/_upstream-controls-inner.sh, and must stay. Those drive
    # UPSTREAM's binary, which understands only the old names, and
    # scripts/verify-upstream-controls.sh measures the difference.
    # E84: the control, and both halves are needed. "global-scope lib" is
    #      printed only from the ENABLED path; "dlopen pass-through" is
    #      printed from both, and a case needling that would pass with the
    #      feature off. Measured on debian:bullseye-slim before this needle
    #      was chosen.
    run E84 OK "global-scope lib" \
        env CROSS_LIBC_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1 \
            LD_PRELOAD=/work/cross-libc-dlopen.so \
            ./loader /work/verprobe.so probe_cond_init

    # E85: the DEBUG alias is gone. Feature on under its new name, so the
    #      interposer IS running and E84 proves it prints; only the debug
    #      control is spelled the old way, so one variable is under test.
    #      ⚠ An absence, and `run` can only assert presence, so the absence is
    #      turned into a word. Reading grep's answer inside the case is the
    #      assertion here, not an exit code being read through a pipe.
    run E85 OK "debug-alias-is-silent" sh -c \
        'out=$(env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_DEBUG=1 \
                   LD_PRELOAD=/work/cross-libc-dlopen.so \
                   ./loader /work/verprobe.so probe_cond_init 2>&1)
         case "$out" in
             *"[cross-libc-dlopen.so]"*) echo "debug-alias-STILL-READ" ;;
             *)                          echo "debug-alias-is-silent" ;;
         esac'

    # E86: the ENABLE alias is gone, and now that the feature is on by default
    #      the way to show that is to try to TURN IT OFF with the old name.
    #      A build that still read the alias would bail at mode=0 here.
    run E86 OK "global-scope lib" \
        env ANYLINUX_LIB_FOREIGN_DLOPEN=0 CROSS_LIBC_DLOPEN_DEBUG=1 \
            LD_PRELOAD=/work/cross-libc-dlopen.so \
            ./loader /work/verprobe.so probe_cond_init

    # ---- on by default, and the off switch that makes the controls work ----
    #
    # ⭐ The point of the default. A consumer that preloads the object and asks
    # for nothing else gets the feature. Before this, it got a run that did
    # nothing and said nothing about why, unless it also shipped a marker file
    # or set a variable.
    #
    # ⚠ CROSS_LIBC_DLOPEN_DEBUG is set only so the object reports what it did.
    # It does not enable anything: E90 has it set too and reads mode=0.
    run E89 OK "global-scope lib" \
        env CROSS_LIBC_DLOPEN_DEBUG=1 LD_PRELOAD=/work/cross-libc-dlopen.so \
            ./loader /work/verprobe.so probe_cond_init

    # E90: and OFF is still reachable, which is what every A/B control in
    #      experiments/40-appimage.sh depends on for its "feature off" arm.
    #      ⛔ Without this, E89 would be a one-sided result: "it is on" means
    #      nothing if it cannot be turned off.
    run E90 OK "attempt bail: mode=0" \
        env CROSS_LIBC_DLOPEN=0 CROSS_LIBC_DLOPEN_DEBUG=1 \
            LD_PRELOAD=/work/cross-libc-dlopen.so \
            ./loader /work/verprobe.so probe_cond_init

    # E24: the trap stated in terms of libc alone -- the obsolete definition
    #      really does reject the attribute Mesa passes.
    # E25: the memcpy exclusion is justified, not assumed.
    # E27: WHICH resolution primitive may be trusted. dlsym(RTLD_NEXT) answers
    #      with the obsolete definition on glibc 2.31 and the default one on
    #      2.41, which is exactly why version-compat.c reads the version name
    #      out of the ELF and uses dlvsym.
    gcc -O2 /repo/tests/vertrap.c -o vertrap -ldl -lpthread 2>"$BERR" || bfail vertrap
    run E24 OK "e24 PASSED" ./vertrap e24
    run E25 OK "e25 PASSED" ./vertrap e25
    run E27 OK "e27 PASSED" ./vertrap e27

    # E26: the audit. A future glibc must not be able to add a trap that
    #      version-compat.c neither forwards nor explicitly declines.
    run E26 OK "every trap in this libc is forwarded" \
        python3 /repo/tools/version_traps.py /lib/$TRIPLET/libc.so.6 \
                --check /repo/src/version-compat.c --quiet

    # ---- I. the failure report says the right thing ----------------------
    #
    # A DT_NEEDED that cannot be opened makes every symbol it would have
    # provided look unresolved. The old report blamed the bundled glibc for
    # all of them and pointed at CROSS_LIBC_DLOPEN_RUNTIME=host, which cannot help --
    # 258 LLVM symbols, none of which any libc has ever exported (issue #1).
    echo
    echo "-- I. diagnosing a dependency that could not be opened ----------"
    cat > vendor.c <<'VEOF'
__attribute__((visibility("default"))) int LLVMGetTargetFromTriple(void) { return 1; }
__attribute__((visibility("default"))) int _ZN4llvm9Attribute16getWithAlignmentEv(void) { return 2; }
VEOF
    cat > user.c <<'UEOF'
extern int LLVMGetTargetFromTriple(void);
extern int _ZN4llvm9Attribute16getWithAlignmentEv(void);
__attribute__((visibility("default")))
int use(void) { return LLVMGetTargetFromTriple() + _ZN4llvm9Attribute16getWithAlignmentEv(); }
UEOF
    gcc -shared -fPIC -O2 vendor.c -o libvendor.so.1 -Wl,-soname,libvendor.so.1
    gcc -shared -fPIC -O2 user.c -o hostdep.so -L"$PWD" -l:libvendor.so.1
    mkdir -p gone && mv libvendor.so.1 gone/      # now unfindable, as on Gentoo

    # E28: the report names the dependency instead of accusing the libc.
    run E28 FAIL "dependencies could not be opened" \
        env CROSS_LIBC_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1 \
            LD_PRELOAD=/work/cross-libc-dlopen.so ./loader /work/hostdep.so use

    # E29: and the message the CALLER gets is still ld.so's, not one of the
    #      report's own dlsym misses. Every failed probe replaces the pending
    #      dlerror(), so without care the app is told this preload has an
    #      undefined symbol -- the wrong object entirely.
    run E29 FAIL "libvendor.so.1: cannot open shared object file" \
        env CROSS_LIBC_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1 \
            LD_PRELOAD=/work/cross-libc-dlopen.so ./loader /work/hostdep.so use
fi

echo
echo "-- K. dlopen scope: what a plugin can see of its loader's closure --"
#
# A driver does not always declare everything it uses. Classic Mesa's DRI
# driver imports _glapi_* with NO DT_NEEDED edge on libglapi.so.0: natively
# that resolves because libGL.so.1 is in the GLOBAL scope and pulled libglapi
# in as its own dependency. A loader that dlopens libGL RTLD_LOCAL breaks that
# without touching either file, and the driver fails with "undefined symbol"
# for a symbol that is present in the process.
#
# Reproduced here in three tiny objects rather than by finding a 2014 Mesa: the
# mechanism is a property of ld.so, not of Mesa, and stating it in twelve lines
# is worth more than a distro that has to be excavated. It is the reason
# src/gl-fwd.c asks for RTLD_GLOBAL -- and the reason it asks only for the ONE
# object it loads, rather than making every cross-libc dlopen global.
cat > prov.c <<'CEOF'
__attribute__((visibility("default"))) int prov_symbol(void) { return 7; }
CEOF
cat > mid.c <<'CEOF'
extern int prov_symbol(void);
__attribute__((visibility("default"))) int mid_entry(void) { return prov_symbol(); }
CEOF
cat > plug.c <<'CEOF'
/* imports prov_symbol with no DT_NEEDED edge to whoever defines it */
extern int prov_symbol(void);
__attribute__((visibility("default"))) int plug_entry(void) { return prov_symbol() + 1; }
CEOF
cat > scope.c <<'CEOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
/* argv[1] = "local" | "global": how the MIDDLE object is loaded. */
int main(int argc, char **argv) {
    int global = argc > 1 && argv[1][0] == 'g';
    void *mid = dlopen("./libmid.so", RTLD_NOW | (global ? RTLD_GLOBAL : RTLD_LOCAL));
    if (!mid) { printf("FAILED: mid: %s\n", dlerror()); return 1; }
    void *plug = dlopen("./libplug.so", RTLD_NOW | RTLD_GLOBAL);
    if (!plug) { printf("FAILED: plugin: %s\n", dlerror()); return 1; }
    int (*f)(void) = dlsym(plug, "plug_entry");
    printf("OK: plug_entry()=%d\n", f ? f() : -1);
    return 0;
}
CEOF
gcc -shared -fPIC -O2 prov.c -o libprov.so -Wl,-soname,libprov.so
gcc -shared -fPIC -O2 mid.c  -o libmid.so  -Wl,-soname,libmid.so -L"$PWD" -l:libprov.so -Wl,-rpath,"$PWD"
gcc -shared -fPIC -O2 plug.c -o libplug.so -Wl,-soname,libplug.so
gcc -O2 scope.c -o scope -ldl

# E54: the loader's closure loaded RTLD_LOCAL. The plugin's undeclared import
#      cannot see it, and the message names a symbol that IS in the process.
run E54 FAIL "undefined symbol: prov_symbol" ./scope local
# E55: the same two files, the middle one RTLD_GLOBAL. Nothing else changed.
run E55 OK   "plug_entry()=8"                ./scope global

echo
echo "-- L. preload constructor order --------------------------------"
#
# gl-fwd.so's constructor dlopens a HOST library, which needs the bundled libc
# runtime set that cross-libc-dlopen.so's constructor puts in the global scope. So
# the order matters, and the intuitive answer is wrong: ld.so runs preload
# constructors in REVERSE of the list. Listing gl-fwd.so after cross-libc-dlopen.so
# -- which is what a reader would write, and what upstream's packaging note said
# -- runs it FIRST. Measured, because the alternative is to depend on it.
cat > ctor.c <<'CEOF'
#include <stdio.h>
__attribute__((constructor)) static void c(void) { fputs(NAME "\n", stderr); }
CEOF
cat > ctormain.c <<'CEOF'
int main(void) { return 0; }
CEOF
gcc -shared -fPIC -DNAME='"ctor-A"' ctor.c -o ctorA.so
gcc -shared -fPIC -DNAME='"ctor-B"' ctor.c -o ctorB.so
gcc -O2 ctormain.c -o ctormain
# E56: A listed first, B listed second -- B's constructor runs first.
run E56 OK "ctor-B" env LD_PRELOAD="$PWD/ctorA.so:$PWD/ctorB.so" ./ctormain
# E57: and it is the ORDER that decides it, not the file: swap them and the
#      first line swaps too. Without this pair, E56 alone cannot tell "reverse
#      order" from "B always happens to go first".
run E57 OK "ctor-A" env LD_PRELOAD="$PWD/ctorB.so:$PWD/ctorA.so" ./ctormain

echo
echo "-- M. a trampoline forwards any signature ----------------------"
#
# src/gl-fwd.c forwards 3470 entry points as two-instruction tail jumps rather
# than as C wrappers, because a wrapper needs a prototype and a wrong prototype
# corrupts arguments silently. The claim being tested is that a tail jump is
# signature-independent: same object, same trampoline, called through six
# different shapes including a float-heavy one and a varargs one.
cat > tgt.c <<'CEOF'
#include <stdarg.h>
#include <string.h>
__attribute__((visibility("default")))
long t_ints(long a, long b, long c, long d, long e, long f, long g, long h) {
    return a + b*2 + c*3 + d*4 + e*5 + f*6 + g*7 + h*8;
}
__attribute__((visibility("default")))
double t_floats(double a, double b, double c, double d,
                double e, double f, double g, double h, double i) {
    return a + b*2 + c*3 + d*4 + e*5 + f*6 + g*7 + h*8 + i*9;
}
__attribute__((visibility("default")))
long t_varargs(const char *fmt, ...) {
    va_list ap; long sum = 0; va_start(ap, fmt);
    for (const char *p = fmt; *p; p++)
        sum += (*p == 'd') ? (long)va_arg(ap, double) : va_arg(ap, long);
    va_end(ap); return sum;
}
struct big { long v[6]; };
__attribute__((visibility("default")))
struct big t_struct(struct big in) { for (int i = 0; i < 6; i++) in.v[i] *= 2; return in; }
CEOF
cat > tramp.c <<'CEOF'
/* the same trampoline shape src/gl-fwd.c generates, by hand for four names */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
__attribute__((visibility("hidden"))) void *glfwd_tab[4];
#define STUB(i, n) __asm__(".text\n.globl " #n "\n.type " #n ",@function\n" \
        #n ":\n\t.byte 0xf3,0x0f,0x1e,0xfa\n\tjmp *glfwd_tab+8*" #i "(%rip)\n")
STUB(0, t_ints);
STUB(1, t_floats);
STUB(2, t_varargs);
STUB(3, t_struct);
extern long t_ints(long, long, long, long, long, long, long, long);
extern double t_floats(double, double, double, double, double, double, double, double, double);
extern long t_varargs(const char *, ...);
struct big { long v[6]; };
extern struct big t_struct(struct big);
static const char *names[4] = { "t_ints", "t_floats", "t_varargs", "t_struct" };
int main(void) {
    void *h = dlopen("./libtgt.so", RTLD_NOW);
    if (!h) { printf("FAILED: %s\n", dlerror()); return 1; }
    for (int i = 0; i < 4; i++) glfwd_tab[i] = dlsym(h, names[i]);
    long i8 = t_ints(1,2,3,4,5,6,7,8);
    double f9 = t_floats(1,2,3,4,5,6,7,8,9);
    long va = t_varargs("dldl", 1.5, 2L, 3.5, 4L);
    struct big in = {{1,2,3,4,5,6}}, out = t_struct(in);
    int ok = (i8 == 204) && (f9 > 284.99 && f9 < 285.01) && (va == 10) &&
             (out.v[0] == 2 && out.v[5] == 12);
    printf("%s: ints=%ld floats=%.2f varargs=%ld struct=[%ld..%ld]\n",
           ok ? "OK" : "FAILED", i8, f9, va, out.v[0], out.v[5]);
    return ok ? 0 : 1;
}
CEOF
gcc -shared -fPIC -O2 tgt.c -o libtgt.so -Wl,-soname,libtgt.so
# E58: eight integer registers, nine float registers, a varargs call whose %al
#      carries the float count, and a struct returned through hidden memory --
#      all through a jump that knows none of their shapes.
#
# ⚠ This section's STUB macro is x86-64 machine code written by hand: an
# endbr64 as four literal bytes, then `jmp *glfwd_tab+8*i(%rip)`. It is a
# miniature of src/gl-fwd.c's trampoline, not that trampoline, and it cannot
# assemble anywhere else. On aarch64 gas rejects it with "unknown mnemonic
# `jmp'", the binary is never produced, and E58 reported "./tramp: No such
# file or directory" -- which names the wrong thing entirely.
#
# The capability this stage lacks on aarch64 is a hand-written x86-64
# trampoline. What the REAL aarch64 trampolines do is measured, on this same
# host, by E69 through E73 in section N and by E76/E76b in section P: those
# build src/gl-fwd.c itself rather than a copy of it.
if [ "$(uname -m)" = x86_64 ]; then
    gcc -O2 $CET tramp.c -o tramp -ldl
    run E58 OK "OK: ints=204" ./tramp
else
    echo "  E58    SKIPPED - section M's trampoline is hand-written x86-64 asm"
    echo "         and this host is $(uname -m). src/gl-fwd.c's own aarch64"
    echo "         trampolines are measured by E69-E73 and E76/E76b."
fi

echo
echo "-- N. the resolver: a table slot that can run code -------------"
#
# E58 measures a trampoline whose slot already holds an address. That design
# could not do anything AT the first call, which cost two things: the host
# stack had to be loaded in every process whether or not it would be used, and
# an entry point the host does not implement was a silent zero.
#
# src/gl-fwd.c now starts every slot at a register-saving resolver and the
# trampoline carries its own index. These cases measure that resolver -- the
# real one, built from src/gl-fwd.c with a four-name table, not a copy of it
# that could drift. libtgt.so from section M is the "host library".
cat > tgt-fwd.h <<'CEOF'
#ifndef GLFWD_SONAME
#define GLFWD_SONAME  "libtgt.so"
#define GLFWD_COUNT   5
#endif
GLFWD_SYM(0, t_ints)
GLFWD_SYM(1, t_floats)
GLFWD_SYM(2, t_varargs)
GLFWD_SYM(3, t_struct)
GLFWD_SYM(4, t_absent)
CEOF
# t_absent is in the table and NOT in libtgt.so, which is the 1097-entry-point
# case in miniature: a name the shim must export and the host cannot provide.
cp /repo/src/gl-fwd.c /repo/src/ld-conf.h /repo/src/cld-env.h .
gcc -shared -fPIC -O2 -Wall -Wextra -Wno-format-truncation $CET \
    -DGLFWD_TABLE='"tgt-fwd.h"' -DGLFWD_TAG='"tgt-fwd.so"' \
    -DGLFWD_GETPROC='"t_getproc"' \
    -Wl,-soname,libtgt.so gl-fwd.c -o tgt-fwd.so -ldl 2>"$BERR" || bfail tgt-fwd.so

cat > tramp2.c <<'CEOF'
/* Calls each entry point TWICE. The first call goes through the resolver with
   every argument still in its register; the second goes through the patched
   slot. If the resolver drops or reorders anything, the two disagree -- and a
   test that called once could not tell the difference. */
#include <stdio.h>
struct big { long v[6]; };
extern long   t_ints(long, long, long, long, long, long, long, long);
extern double t_floats(double, double, double, double, double, double, double, double, double);
extern long   t_varargs(const char *, ...);
extern struct big t_struct(struct big);
extern long   t_absent(long, long);
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    long   i1 = t_ints(1,2,3,4,5,6,7,8),   i2 = t_ints(1,2,3,4,5,6,7,8);
    double f1 = t_floats(1,2,3,4,5,6,7,8,9), f2 = t_floats(1,2,3,4,5,6,7,8,9);
    long   v1 = t_varargs("dldl", 1.5, 2L, 3.5, 4L),
           v2 = t_varargs("dldl", 1.5, 2L, 3.5, 4L);
    struct big in = {{1,2,3,4,5,6}}, s1 = t_struct(in), s2 = t_struct(in);
    long   a1 = t_absent(7, 9);
    int first = (i1 == 204) && (f1 > 284.99 && f1 < 285.01) && (v1 == 10) &&
                (s1.v[0] == 2 && s1.v[5] == 12);
    int same  = (i1 == i2) && (f1 == f2) && (v1 == v2) &&
                (s1.v[0] == s2.v[0] && s1.v[5] == s2.v[5]);
    printf("%s: first-call ints=%ld floats=%.2f varargs=%ld struct=[%ld..%ld]"
           " second-call-identical=%s absent-returned=%ld\n",
           (first && same && a1 == 0) ? "OK" : "FAILED",
           i1, f1, v1, s1.v[0], s1.v[5], same ? "yes" : "no", a1);
    return (first && same && a1 == 0) ? 0 : 1;
}
CEOF
cat > mapped.c <<'CEOF'
/* Links the shim's soname. With no argument it calls NOTHING; with one it
   makes a single call. Then it asks the KERNEL what is mapped, because "it
   started faster" is not evidence about what was loaded. */
#include <stdio.h>
#include <string.h>
extern long t_ints(long, long, long, long, long, long, long, long);
int main(int argc, char **argv) {
    long called = (argc > 1) ? t_ints(1,2,3,4,5,6,7,8) : -1;
    FILE *f = fopen("/proc/self/maps", "r");
    char line[4096]; int host = 0, shim = 0;
    while (f && fgets(line, sizeof line, f)) {
        if (strstr(line, "/libtgt.so"))  host = 1;
        if (strstr(line, "/tgt-fwd.so")) shim = 1;
    }
    if (f) fclose(f);
    int want_host = (argc > 1);
    int ok = shim && (host == want_host);
    printf("%s: shim mapped=%d target mapped=%d (called=%ld)\n",
           ok ? "OK" : "FAILED", shim, host, called);
    return ok ? 0 : 1;
}
CEOF
# Linked against the SHIM, not against libtgt.so: the shim carries libtgt.so's
# SONAME, so DT_NEEDED reads libtgt.so and ld.so binds it to whichever object
# claims that name -- which is the whole mechanism, reproduced in miniature.
# t_absent exists only in the shim, so this is also the only thing that links.
# --no-as-needed because mapped.c with no argument references nothing, and the
# default would drop the DT_NEEDED that the case is about.
gcc -O2 $CET tramp2.c -o tramp2 ./tgt-fwd.so -Wl,-rpath,"$PWD"
gcc -O2 $CET mapped.c -o mapped ./tgt-fwd.so -Wl,--no-as-needed \
    -Wl,-rpath,"$PWD"

# The shim owns libtgt.so's soname, so the ONE name it is allowed to resolve
# cannot come from ld.so -- ld.so would hand back the shim. CROSS_LIBC_DLOPEN_GL_HOST_DIR
# is the handoff that names the directory to look in.
fwd() { env LD_PRELOAD="$PWD/tgt-fwd.so" CROSS_LIBC_DLOPEN_GL_HOST_DIR="$PWD" "$@"; }

# E69: eight integer registers, nine float registers, a varargs %al count and a
#      struct returned through hidden memory -- all surviving a C call made in
#      the MIDDLE of the forward. And the second call agrees with the first,
#      which is what says the slot was patched with the right address rather
#      than that the resolver got lucky once.
run E69 OK "OK: first-call ints=204" fwd ./tramp2

# E70: and it really was resolved at the CALL and not in a constructor. If
#      anything ever moves the load back into the constructor, this notices.
run E70 OK "none resolved yet" fwd env CROSS_LIBC_DLOPEN_DEBUG=1 ./tramp2

# E71/E71b: B4, asked of /proc/self/maps. Same binary, one argument apart: a
#      process that links the soname and calls nothing must not map the target,
#      and the same process that makes ONE call must. Single-sided, E71 would
#      also pass if the shim were simply broken.
run E71  OK "shim mapped=1 target mapped=0" fwd ./mapped
run E71b OK "shim mapped=1 target mapped=1" fwd ./mapped call

# E72: B1. The entry point the host does not implement is CALLED, and the shim
#      names it. Before the resolver existed this returned zero in silence,
#      which is the failure mode this repository warns about most.
run E72 OK "ABSENT entry point called: t_absent" \
    fwd env CROSS_LIBC_DLOPEN_DEBUG=1 ./tramp2

# E73: and the number an application can now be measured by -- how much of a
#      dispatcher it actually touches. Five names, four the host has, five
#      called. This is the counter B6 needs to stop guessing with.
run E73 OK "5 of 5 entry points were CALLED (4 forwarded, 1 absent)" \
    fwd env CROSS_LIBC_DLOPEN_DEBUG=1 ./tramp2

echo
echo "-- O. the shim asks the HOST where its libraries are ------------"
#
# The shim resolves exactly one soname, because ld.so cannot -- that name is
# taken by the shim itself. WHERE it looks used to be a hardcoded list of
# conventional directories, and that list was a guess about somebody else's
# packaging. It drifted: Ubuntu's alternatives layout puts classic libGL.so.1
# in <triplet>/mesa and classic libEGL.so.1 in <triplet>/mesa-egl, the list had
# the first and not the second, and EGL therefore failed on every pre-glvnd
# Ubuntu while GL worked. Reported from outside, by @Samueru-sama.
#
# The repair is to stop guessing: /etc/ld.so.conf is where the host writes its
# own answer down, in plain text, and src/ld-conf.h is now the ONE walk of it
# that both gl-fwd.c and runtime-select.c use.
#
# Measured on a directory no list could contain, so a pass cannot come from the
# hardcoded entries. The control is the same run with the conf file removed --
# the mechanism's own presence, not an env switch invented to disable it.
mkdir -p /opt/cross-libc-unguessable-42 /etc/ld.so.conf.d
cp libtgt.so /opt/cross-libc-unguessable-42/libtgt.so
[ -f /etc/ld.so.conf ] || printf 'include /etc/ld.so.conf.d/*.conf\n' > /etc/ld.so.conf
confdir() { printf '/opt/cross-libc-unguessable-42\n' > /etc/ld.so.conf.d/zz-cross-libc.conf; }
noconf()  { rm -f /etc/ld.so.conf.d/zz-cross-libc.conf; }
# No CROSS_LIBC_DLOPEN_GL_HOST_DIR here: the whole question is whether the shim finds it
# without being told, so the handoff that would tell it is left out.
fwd_noenv() { env LD_PRELOAD="$PWD/tgt-fwd.so" CROSS_LIBC_DLOPEN_DEBUG=1 "$@"; }

# E75: the directory is named ONLY by /etc/ld.so.conf.d, and the shim finds it.
confdir
run E75 OK "target /opt/cross-libc-unguessable-42/libtgt.so" fwd_noenv ./tramp2
# E75b: the control that must FAIL. Same directory, same library, same
#       binary -- conf file gone, so nothing names it and the shim comes up
#       empty. Without this, E75 would also pass if the shim had simply
#       guessed the directory, which is the habit being removed.
noconf
run E75b FAIL "no target; all 5 entry points return zero" fwd_noenv ./tramp2
# Left REMOVED, not restored: section P runs after this one and its aarch64
# shim would otherwise find the x86-64 libtgt.so through this very conf file.
rm -rf /opt/cross-libc-unguessable-42

echo
echo "-- P. the aarch64 trampolines, RUN -----------------------------"
#
# "It assembles" is a weaker claim than "it works", and until now the aarch64
# half of src/gl-fwd.c had only the weaker one: make gl-fwd-asm-check produced
# correct instructions and correct relocations and executed none of them.
#
# This machine is x86_64 and there is no aarch64 silicon to borrow, but there
# does not have to be. qemu-user runs an aarch64 binary on an x86_64 kernel in
# userspace, and everything under test here IS userspace: the trampoline, the
# register-saving resolver, ld.so's binding of a DT_NEEDED to a preloaded
# object with the same SONAME, and dlopen.
#
# qemu-aarch64-static is invoked BY NAME rather than through binfmt_misc. A
# binfmt handler is a kernel registration that outlives the container and
# changes how the machine treats every aarch64 file afterwards; naming the
# emulator changes nothing outside this process. It also needs no --privileged.
#
# ⚠ Do NOT reach for `podman run --platform linux/arm64` instead. Pulling a tag
# for another platform REPLACES the cached image for that tag, so the next run
# of the suite gets `exec container process: Exec format error` from an image
# it has used a hundred times. That cost a run here.
# ⭐ WHEN THE HOST IS THE TARGET, DO NOT EMULATE IT. Everything above was
# written on an x86_64 machine, where qemu-user is the only way to run these
# instructions at all. CI now also runs this stage on ubuntu-24.04-arm, and
# there the emulator is not a bridge, it is a layer between the trampoline and
# the CPU that is the whole reason for running there.
#
# ⛔ Measured: on that runner E76 and E76b passed THROUGH qemu-aarch64-static,
# on aarch64 silicon. .github/workflows/gates.yml added that runner saying in
# so many words that qemu "emulates the instructions and not a memory model",
# so the one host where the memory model is real was the one host still not
# using it. docs/REPORT.md 9.16.
#
# The prediction is identical on both paths. Only the vehicle differs, and the
# vehicle is PRINTED, because a reader looking at one log has no other way to
# tell which of the two produced it.
a64_vehicle=''
if [ "$(uname -m)" = aarch64 ]; then
    A64=gcc
    a64_vehicle="native: the host IS aarch64, no emulator in the path"
    a64run()  { env LD_PRELOAD="$PWD/tgt-fwd.so" \
                    CROSS_LIBC_DLOPEN_GL_HOST_DIR="$PWD" "$@"; }
    a64dbg()  { env LD_PRELOAD="$PWD/tgt-fwd.so" \
                    CROSS_LIBC_DLOPEN_GL_HOST_DIR="$PWD" \
                    CROSS_LIBC_DLOPEN_DEBUG=1 "$@"; }
elif command -v qemu-aarch64-static >/dev/null 2>&1 &&
     command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    A64=aarch64-linux-gnu-gcc
    a64_vehicle="qemu-user on $(uname -m): userspace emulation, not a memory model"
    a64run()  { qemu-aarch64-static -L /usr/aarch64-linux-gnu \
                    -E LD_PRELOAD="$PWD/tgt-fwd.so" \
                    -E CROSS_LIBC_DLOPEN_GL_HOST_DIR="$PWD" "$@"; }
    a64dbg()  { qemu-aarch64-static -L /usr/aarch64-linux-gnu \
                    -E LD_PRELOAD="$PWD/tgt-fwd.so" \
                    -E CROSS_LIBC_DLOPEN_GL_HOST_DIR="$PWD" \
                    -E CROSS_LIBC_DLOPEN_DEBUG=1 "$@"; }
else
    A64=''
fi

if [ -z "$A64" ]; then
    skip E76 "no qemu-aarch64-static or aarch64-linux-gnu-gcc: apt-get install qemu-user-static gcc-aarch64-linux-gnu libc6-dev-arm64-cross"
    skip E76b "as E76"
else
    echo "   vehicle: $a64_vehicle"
    # Absolute, both ways: `cd a64 && ...` followed by `cd ..` walks out of
    # /work entirely if the copy failed, and everything after it then runs
    # somewhere unexpected.
    mkdir -p /work/a64
    cp gl-fwd.c ld-conf.h cld-env.h tgt.c tgt-fwd.h tramp2.c /work/a64/
    cd /work/a64
    $A64 -shared -fPIC -O2 tgt.c -o libtgt.so -Wl,-soname,libtgt.so 2>"$BERR" || bfail "libtgt.so (aarch64)"
    $A64 -shared -fPIC -O2 -Wall -Wextra -Wno-format-truncation \
         -DGLFWD_TABLE='"tgt-fwd.h"' -DGLFWD_TAG='"tgt-fwd.so"' \
         -DGLFWD_GETPROC='"t_getproc"' \
         -Wl,-soname,libtgt.so gl-fwd.c -o tgt-fwd.so -ldl 2>"$BERR" || bfail tgt-fwd.so
    $A64 -O2 tramp2.c -o tramp2 ./tgt-fwd.so 2>"$BERR" || bfail "tramp2 (aarch64)"
    # E76: the same four shapes E69 puts through the x86-64 resolver, through
    #      the aarch64 one. x0-x7, x8's indirect-result pointer and q0-q7 all
    #      surviving a bl in the middle of the forward, and the index arriving
    #      in x17 because x16 was already the branch register.
    run E76 OK "OK: first-call ints=204" a64run ./tramp2
    # E76b: and the absent path, which is the arch-specific `mov x0,#0 / movi
    #       d0,#0` rather than x86-64's `xor/pxor`.
    run E76b OK "ABSENT entry point called: t_absent" a64dbg ./tramp2
    cd ..
fi

echo
echo "================================================================"
echo " predictions matched: $PASS   mismatched: $FAIL"
echo "================================================================"
[ "$FAIL" -eq 0 ]
