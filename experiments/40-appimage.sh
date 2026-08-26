#!/bin/sh
# The end-to-end suite: a real AppImage, a real host driver, on a host whose
# libc is not the AppImage's.  Runs INSIDE the host container.
#
#   /w/AppDir   the extracted demo AppImage (upstream's foreign-dlopen.so kept
#               beside it as foreign-dlopen.upstream.so)
#   /w/build    cross-libc-dlopen.so and the test binaries, built on the glibc
#               FLOOR so they only need old symbols
#
# Every case states its PREDICTION and the harness reports MATCH / MISMATCH.
# A MISMATCH is a finding. Nothing here is single-sided: the feature is always
# measured off and on, because "it rendered" on its own cannot tell a working
# fix from a fallback that was already happening.
set -u

APPDIR=/w/AppDir
LP="$APPDIR/lib"
# ⚠ The bundled loader's name and musl's soname carry the architecture.
# Derived from uname -m, the same way scripts/suite-lib.sh derives the asset
# suffix, so this stage runs on the aarch64 AppImage as well as the x86-64 one.
# ⛔ $MUSL_SO is both an emitter and a MATCHER here: E48's needle is the musl
# soname the bundled ld.so fails to find, so the two move together or E48 stops
# asserting what it was written to assert.
case "$(uname -m)" in
    x86_64)  LDSO=ld-linux-x86-64.so.2 ; MUSL_SO=libc.musl-x86_64.so.1  ;;
    aarch64) LDSO=ld-linux-aarch64.so.1; MUSL_SO=libc.musl-aarch64.so.1 ;;
    *) echo "  FATAL: no loader and musl soname known for $(uname -m)"; exit 1 ;;
esac
LD="$LP/$LDSO"
export APPDIR
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg}
mkdir -p "$XDG_RUNTIME_DIR"
PASS=0; FAIL=0; SKIP=0
# Per-case wall time, for T-12. Written by run(), reported at the end.
TIMINGS=/tmp/cld-timings.tsv
: > "$TIMINGS"
# Extra host library directories for the OpenGL cases. Empty unless E77's
# pre-flight finds this host's driver cannot load without them; declared here
# because `set -u` makes reading it before section J a fatal error rather
# than an empty string.
GLPATH=""
XA='-screen 0 1024x768x24 +extension GLX +extension RANDR +render' 

# 41-extract.sh keeps upstream's shim beside the AppDir at extraction time. If it
# is missing, the AppDir has been used before and lib/foreign-dlopen.so is
# whatever the last run left there -- copying that as "upstream" would quietly
# run the entire A/B against the patched build twice and report it as a pass.
if [ ! -f "$LP/foreign-dlopen.upstream.so" ] || [ ! -f "$APPDIR/.preload.shipped" ]; then
    echo "  FATAL: $LP/foreign-dlopen.upstream.so or $APPDIR/.preload.shipped is missing."
    echo "  The AppDir is stale. Delete .tmp/AppDir and re-run so extraction can"
    echo "  preserve BOTH the shipped shim and the shipped .preload; without the"
    echo "  first the 'as shipped' cases silently measure the patched build, and"
    echo "  without the second the OpenGL cases that must run with NO shim would"
    echo "  run with whatever the last run left in .preload."
    exit 2
fi

# ⚠ RESET THE APPDIR BEFORE ANYTHING RUNS.
#
# The AppDir is shared state in a gitignored directory, it survives between
# runs, and section J deliberately rewrites .preload. That is fine when the
# suite is the only thing touching it -- and it is not: debugging one host by
# hand leaves the GL shims in .preload, and the NEXT full run then executes
# sections A through I with shims that those cases know nothing about. It
# happened in this repository and it cost a run: E53 and E53b failed on
# hardware that was working, and E59 counted eleven bundled loaders that were
# not bundled.
#
# The guard above catches a missing baseline. This catches a dirty one, which
# is the more common and much quieter of the two.
reset_appdir() {
    cp "$APPDIR/.preload.shipped" "$APPDIR/.preload"
    rm -f "$LP/gl-fwd.so" "$LP/egl-fwd.so"
    # Probes and demo binaries that section J installs, and anything a hand-run
    # left beside them. Only names this suite creates are removed.
    for p in glprobe eglprobe; do
        rm -f "$APPDIR/shared/bin/$p" "$APPDIR/bin/$p"
    done
}
stray=$(ls "$APPDIR/shared/bin" 2>/dev/null | grep -vxE 'eglgears_wayland|eglgears_x11|eglprobe|glprobe|glxgears|vkcube|vkmark' | tr '\n' ' ')
if [ -n "$stray" ]; then
    echo "  FATAL: $APPDIR/shared/bin holds files this AppImage does not ship: $stray"
    echo "  The AppDir has been written to by something other than this suite."
    echo "  Delete .tmp/AppDir and re-run so extraction can rebuild it."
    exit 2
fi
reset_appdir

# ONE NAME HERE IS NOT THIS PROJECT'S, and renaming it would turn E30, E37a
# and E43a -- the controls the whole A/B rests on -- into silent passes:
#
#   $LP/foreign-dlopen.so     the slot quick-sharun writes and .preload names.
#                             Our build is copied INTO it; the path stays
#                             upstream's because .preload says so.
#
# ⚠ .foreign-dlopen-enabled USED TO BE THE SECOND, and is not any more. It is
# quick-sharun's opt-in marker and it is still present in the AppDir, but
# nothing in src/ reads it: the markers were removed and the feature is on by
# default whenever the object is preloaded. Whether upstream's own binary
# still reads it is not measured here and no case below depends on the answer,
# because every arm sets the variable explicitly. docs/REPORT.md 9.16.
#
# And every `env` below sets the OLD variable spelling beside the new one,
# because upstream's binary only understands the old one. Losing it does not
# produce a failure: E30 predicts NO-DEVICES, and upstream run with the
# feature OFF also reports NO-DEVICES. The case would go green having
# measured nothing.
use_preload() {                # upstream | patched
    case "$1" in
        upstream) cp "$LP/foreign-dlopen.upstream.so" "$LP/foreign-dlopen.so" ;;
        patched)  cp /w/build/cross-libc-dlopen.so       "$LP/foreign-dlopen.so" ;;
    esac
}

# One line out of a probe's output, for the report column. A probe that states
# its own verdict on a line of its own gets that line; anything else falls back
# to the first interesting-looking line. Without the first pass the fallback
# pattern wins on an incidental match -- "provenance: .../libcuda.so.1" contains
# "libc" -- and the report shows a neutral line for a case that failed loudly.
summarise() {                  # summarise <text>
    printf '%s' "$1" | grep -m1 -E '^(OK|FAILED|BINDINGS|SOAK|INVARIANTS|ABI)' ||
    printf '%s' "$1" | grep -m1 -iE 'GPU|GL_RENDERER|device|libc|load|SOAK|OK:|FAIL|zero|Error' ||
    printf '%s' "$1" | head -1
}

run() {                        # run <id> <expect: OK|FAIL> <needle> <cmd...>
    id="$1"; want="$2"; needle="$3"; shift 3
    # ⚠ T-12. Every wall-clock timeout in this file was tuned on one developer
    # machine, and a timeout is scored as a FAILURE rather than a skip, so a
    # slow shared runner turns into a red build that looks like a regression.
    # Until the real times are known, the first genuinely red run cannot be
    # told apart from a slow runner.
    #
    # Recorded here, at whole-second resolution, which is enough for values
    # between 25 and 90. This wraps the same command and changes no assertion:
    # the case is scored below exactly as it was.
    _t0=$(date +%s 2>/dev/null || echo 0)
    out=$("$@" 2>&1); rc=$?
    _t1=$(date +%s 2>/dev/null || echo 0)
    printf '%s\t%s\n' "$((_t1 - _t0))" "$id" >> "$TIMINGS" 2>/dev/null || true
    got=OK; [ $rc -ne 0 ] && got=FAIL
    verdict=MISMATCH
    if [ "$got" = "$want" ] && printf '%s' "$out" | grep -qF "$needle"; then
        verdict=MATCH; PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
    printf '  %-6s %-8s predicted=%-4s  %s\n' "$id" "$verdict" "$want" \
        "$(summarise "$out" | cut -c1-96)"
}

skip() { SKIP=$((SKIP+1)); printf '  %-6s %-8s %s\n' "$1" "SKIPPED" "$2"; }

# For cases whose measurement is a NUMBER rather than a string in some output.
# The verdict is computed here rather than inside $( ), because incrementing
# PASS inside a command substitution increments it in a subshell and the totals
# then silently disagree with the per-line verdicts.
verdict() {                    # verdict <id> <0|1 ok> <text>
    if [ "$2" = 1 ]; then PASS=$((PASS+1)); v=MATCH; else FAIL=$((FAIL+1)); v=MISMATCH; fi
    printf '  %-6s %-8s %s\n' "$1" "$v" "$3"
}

# Run something under the BUNDLED loader with the preload, feature forced.
under() {                      # under <0|1> <prog> [args...]
    mode="$1"; shift
    env CROSS_LIBC_DLOPEN="$mode" ANYLINUX_LIB_FOREIGN_DLOPEN="$mode" APPDIR="$APPDIR" \
        "$LD" --library-path "$LP" --preload "$LP/foreign-dlopen.so" "$@"
}

# The same, plus one host directory appended AFTER the bundled ones, for the
# vendor-driver cases. A proprietary driver dlopens the rest of its own stack by
# BARE SONAME, which cross-libc-dlopen deliberately never intercepts, so ld.so has
# to be able to find it -- and ld.so here is the patched one with the cache
# inhibited, so --library-path is the only mechanism left (E13b). Bundled
# directories stay FIRST so bundled libraries keep winning (section 7).
under_at() {                   # under_at <0|1> <extra-dirs> <prog> [args...]
    mode="$1"; extra="$2"; shift 2
    env CROSS_LIBC_DLOPEN="$mode" ANYLINUX_LIB_FOREIGN_DLOPEN="$mode" APPDIR="$APPDIR" \
        "$LD" --library-path "$LP${extra:+:$extra}" \
        --preload "$LP/foreign-dlopen.so" "$@"
}

# vkprobe reduced to one word, because "it did not work" arrives in three
# different shapes -- an error code, a refusal to load, or a segfault -- and a
# harness that only recognises one of them scores a crash as a MISMATCH and
# hides what actually happened.
probe_verdict() {              # probe_verdict <0|1>
    out=$(under "$1" /w/build/vkprobe 2>&1)
    case "$out" in
        *"OK: 1 physical device"*)
            echo "DEVICES  ($(printf '%s' "$out" | grep -m1 'device\['))" ;;
        "") echo "NO-DEVICES  (crashed with no output)" ;;
        *)  echo "NO-DEVICES  ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70))" ;;
    esac
}

# Likewise for rendering: vkcube exits 0 whether or not it found a GPU, so the
# exit code carries no information and the OUTPUT is the whole measurement.
render_verdict() {             # render_verdict <binary> [args...]
    bin="$1"; shift
    out=$(env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" LIBGL_ALWAYS_SOFTWARE=1 \
          timeout 90 xvfb-run -a -s "$XA" "$APPDIR"/AppRun.sh "$bin" "$@" 2>&1)
    printf '%s' "$out" | grep -m1 -E 'Selected GPU|GL_RENDERER|zero accessible|rror' \
        || echo "no recognisable output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"
}

# The same, on HARDWARE. Mesa's d3d12 gallium driver turns /dev/dxg into a real
# GL device; the adapter is named rather than left to chance so the result says
# which of the two GPUs in this machine actually drew the frames.
#   $1 = 0|1 feature   $2 = extra library dirs for sharun ("" for none)
#
# timeout 25, not 90: glxgears never exits on its own, so the timeout IS the
# runtime of the case. GL_RENDERER is printed before the first frame and the
# first FPS line lands at 5 s, so 25 s is five times the margin and saves three
# minutes a run over the 90 s the software cases need for 20 vkcube frames.
render_verdict_hw() {          # render_verdict_hw <0|1> <extra-dirs> <bin> [args...]
    mode="$1"; extra="$2"; bin="$3"; shift 3
    out=$(env CROSS_LIBC_DLOPEN="$mode" ANYLINUX_LIB_FOREIGN_DLOPEN="$mode" APPDIR="$APPDIR" \
          SHARUN_FALLBACK_LIBRARY_PATH="$extra" \
          GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
          LIBGL_ALWAYS_SOFTWARE=0 \
          timeout 25 xvfb-run -a -s "$XA" "$APPDIR"/AppRun.sh "$bin" "$@" 2>&1)
    printf '%s' "$out" | grep -m1 -E 'GL_RENDERER|rror' \
        || echo "no recognisable output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"
}

# The directories the DISTRO itself names, read out of the plain-text
# /etc/ld.so.conf. This is the same computation as rs_conf_dirs() in
# src/runtime-select.c, and the counterpart of get_ld_cache_dirs() that sharun
# now does upstream; a shell stand-in here so the cases can show what the path
# is missing without building sharun.
conf_dirs() {
    awk '{sub(/#.*/,"")} NF' /etc/ld.so.conf 2>/dev/null | while read -r kw rest; do
        if [ "$kw" = include ]; then
            for f in $rest; do
                awk '{sub(/#.*/,"")} NF && $1!="include" {print $1}' $f 2>/dev/null
            done
        else printf '%s\n' "$kw"; fi
    done | sort -u | tr '\n' ':' | sed 's/:$//'
}

# ---------------------------------------------------------------- discovery
#
# A host with no software Vulkan ICD used to end the run here. That was right
# while every host was a Vulkan host; it stopped being right the moment the
# pre-glvnd glibc distros became a target, because Ubuntu 14.04's Mesa 10.1
# predates Vulkan entirely and section J -- the reason to run there at all --
# needs no Vulkan. So a missing ICD SKIPS the cases that need a device, by
# name, and the rest of the suite runs (section 7's rule).
ICD=$(ls /usr/share/vulkan/icd.d/*lvp*.json 2>/dev/null | head -1)
HAVE_VK=yes
LVP=""; ABS=no
if [ -z "$ICD" ]; then
    HAVE_VK=no
else
    export VK_DRIVER_FILES="$ICD"
    # The library the manifest actually names. Alpine and Gentoo use an absolute
    # path here, Debian a bare soname; cross-libc-dlopen only ever intercepts absolute
    # paths, so a bare soname means the feature is a no-op on that host.
    LVP=$(sed -n 's/.*"library_path"[^"]*"\([^"]*\)".*/\1/p' "$ICD" | head -1)
    case "$LVP" in
        /*) ABS=yes ;;
        *)  ABS=no; LVP=$(ls /usr/lib/"$LVP" /usr/lib/*/"$LVP" 2>/dev/null | head -1) ;;
    esac
fi
HOSTLIBC=musl; [ -e "/lib/$MUSL_SO" ] || HOSTLIBC=glibc

# Everything a Vulkan device is needed for. Named once so a host that cannot
# provide one produces one reason repeated, rather than a different guess per
# section about why a case did not appear.
VK_WHY="no software Vulkan ICD on this host: its Mesa has no lavapipe, so there is no device for this case to find"
vk_skip() { for id in "$@"; do skip "$id" "$VK_WHY"; done; }

echo "================================================================"
if [ "$HAVE_VK" = yes ]; then
    echo " AppImage end-to-end   host libc=$HOSTLIBC   ICD=$LVP"
    echo "   manifest library_path is $( [ $ABS = yes ] && echo 'absolute (feature can engage)' || echo 'a bare soname (feature never engages -- forcing an absolute manifest)' )"
else
    echo " AppImage end-to-end   host libc=$HOSTLIBC   ICD=none"
    echo "   $VK_WHY"
    echo "   sections A-E and H are SKIPPED by name; F, G and J still run"
fi
echo "================================================================"

if [ "$HAVE_VK" = yes ] && [ "$ABS" = no ]; then
    printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s","api_version":"1.3.0"}}\n' \
        "$LVP" > /tmp/lvp_abs.json
    export VK_DRIVER_FILES=/tmp/lvp_abs.json
fi

echo
echo "-- reference: is the host driver healthy at all? (ladder rung 1) --"
if [ "$HAVE_VK" = no ]; then
    echo "  no Vulkan on this host; rung 1 for its OpenGL is 'is there a"
    echo "  libGL.so.1 at all', which section J prints"
elif command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary 2>&1 | grep -m1 -E 'deviceName|ERROR' | sed 's/^/  /'
else
    echo "  vulkaninfo absent, skipping the native reference"
fi

# ---------------------------------------------------------------- the A/B
echo
echo "-- A. the host ICD, through the bundled glibc runtime ------------"
if [ "$HAVE_VK" = no ]; then
    vk_skip E30 E31 E32
else
# E30: the AppImage exactly as it ships. This is the reported bug.
use_preload upstream
run E30 OK "NO-DEVICES" probe_verdict 1
use_preload patched
# E31: the control. With the feature off the host driver is simply unusable,
#      which is what makes E32 a measurement rather than a coincidence.
run E31 OK "NO-DEVICES" probe_verdict 0
# E32: the fix.
run E32 OK "DEVICES  " probe_verdict 1
fi

echo
echo "-- A2. how much did it have to rewrite? --------------------------"
if [ "$HAVE_VK" = no ]; then
    vk_skip E39
else
# Rewriting is not free: every rewritten object is a private copy loaded from a
# path the application did not ask for, and the Vulkan loader says so out loud.
# It should happen when it is NEEDED and not otherwise. On a glibc host older
# than the bundled glibc, nothing can be missing, so the right number is zero.
rm -f "$XDG_RUNTIME_DIR"/.cross-libc-dlopen-* 2>/dev/null
trace=$(env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 \
        "$LD" --library-path "$LP" --preload "$LP/foreign-dlopen.so" \
        /w/build/vkprobe 2>&1)
rw=$(printf '%s' "$trace" | grep -c 'cross-libc-dlopen: rewriting')
kept=$(printf '%s' "$trace" | grep -c 'needs no rewrite')
if [ "$HOSTLIBC" = musl ]; then
    [ "$rw" -gt 0 ] && r39=1 || r39=0
    verdict E39 "$r39" "musl host: $rw object(s) rewritten, $kept left unchanged (rewriting is unavoidable here)"
else
    [ "$rw" -eq 0 ] && r39=1 || r39=0
    verdict E39 "$r39" "glibc host: $rw object(s) rewritten, $kept left unchanged (zero is the right answer)"
fi
fi

echo
echo "-- B. how much of the host's /usr/lib is loadable ----------------"
if [ "$HAVE_VK" = no ]; then
    # The corpus directory is "wherever the ICD lives", so with no ICD there is
    # no principled directory to sweep. Guessing one would measure a different
    # question on this host from the one it measures on the others.
    vk_skip E33 E34 E35 E36
else
# Where the host actually keeps its libraries: the directory the ICD lives in,
# not a guess. Debian puts them under /usr/lib/<triplet>, Alpine in /usr/lib.
CORPUS=$(dirname "$LVP")
under 1 /w/build/corpus "$CORPUS" 2>/dev/null > /tmp/corpus_on.txt
under 0 /w/build/corpus "$CORPUS" 2>/dev/null > /tmp/corpus_off.txt
total=$(grep -cE '^(OK|FAIL)' /tmp/corpus_on.txt)
off=$(grep -c '^OK' /tmp/corpus_off.txt)
on=$(grep -c '^OK' /tmp/corpus_on.txt)
echo "  corpus directory: $CORPUS  ($total libraries)"

# The verdicts are computed OUTSIDE a command substitution. Incrementing PASS
if [ "$HOSTLIBC" = musl ]; then
    # Nothing built against musl can load without the fix, and essentially
    # everything should with it.
    [ "$off" -lt $((total / 10)) ] && r33=1 || r33=0
    [ "$on" -gt $((total * 9 / 10)) ] && r34=1 || r34=0
else
    # A glibc host can already load its own libraries, so the bar here is that
    # the feature does not make things WORSE. That is the regression this
    # whole case exists to catch.
    r33=1
    [ "$on" -ge "$off" ] && r34=1 || r34=0
fi
verdict E33 "$r33" "feature off: $off / $total load"
verdict E34 "$r34" "feature on : $on / $total load"
# Name what did not load, so a number that looks fine cannot hide a regression.
grep '^FAIL' /tmp/corpus_on.txt | head -3 | sed 's/^/         still failing: /'

echo
echo "-- C. invariants: exactly one libc family, bundled sonames win ---"
run E35 OK "T4.1 PASS" under 1 /w/build/invariants "$LVP"

echo
echo "-- D. does it keep working ---------------------------------------"
run E36 OK "SOAK PASSED" under 1 /w/build/soak "$LVP" 100
fi

# ---------------------------------------------------------------- rendering
echo
echo "-- E. rendering ---------------------------------------------------"
if [ "$HAVE_VK" = no ]; then
    vk_skip E37a E37 E40
elif ! command -v xvfb-run >/dev/null 2>&1; then
    skip E37 "no xvfb-run on this host: install xvfb"
else
    # E37a: vkcube exactly as the AppImage ships. This is the complaint.
    use_preload upstream
    run E37a OK "zero accessible devices" render_verdict vkcube --c 20
    # E37: the same command with the preload built from src/.
    use_preload patched
    run E37 OK "Selected GPU" render_verdict vkcube --c 20

    # E40: the whole thing stated the way a user would.
    #
    # Replace exactly one file inside the AppDir, lib/foreign-dlopen.so, and run
    # it. No CROSS_LIBC_DLOPEN_* variables and no VK_DRIVER_FILES: the feature
    # is ON BY DEFAULT once the object is preloaded, so it turns itself on and
    # the Vulkan loader finds the host's ICD by itself.
    #
    # ⚠ This comment used to say the AppDir's .foreign-dlopen-enabled marker
    # was what turned it on. That was true when the marker was read and it is
    # not now: the markers were removed, nothing in src/ reads that file, and
    # the case has been passing for the other reason since. The claim the case
    # makes did not change and got stronger, which is exactly why nobody
    # noticed. docs/REPORT.md 9.16.
    #
    # Every other case here forces something -- the feature, the ICD, the
    # loader. This one forces nothing, which is the only version of the claim
    # that matches what was actually asked.
    run E40 OK "Selected GPU" env -u VK_DRIVER_FILES APPDIR="$APPDIR" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" sh -c \
        "timeout 90 xvfb-run -a -s '$XA' $APPDIR/AppRun.sh vkcube --c 20 2>&1 | tail -4"

    # E38 was here: glxgears, run on a host that has a libglvnd vendor library
    # and SKIPPED on one that does not. It is retired rather than renumbered,
    # because its skip reason carried a verdict -- "no loader shim can supply a
    # file the distribution does not ship" -- that was never tested and turned
    # out to be wrong. Section J replaces it with E61 and E62, which measure
    # BOTH host classes instead of declining to look at one of them.
fi

# ------------------------------------ F. a CLOSED-SOURCE driver, real silicon
#
# Everything above runs against open-source Mesa: inspectable, rebuildable, and
# when it broke, its __FILE__ strings and a -dbgsym package said where. This
# section is the one class of host library none of that is true for.
#
# The target is NVIDIA's WSL CUDA userspace, reachable through /dev/dxg. Read
# the results in this order, because the headline is not the one you expect:
#
#   E41/E41b  it works -- AND SO DOES THE CONTROL. A vendor ships against the
#             oldest floor it can (this one is GLIBC_2.2.5), so a proprietary
#             driver is the LEAST likely host library to need this fix. The
#             claim these two cases support is the regression claim.
#   E42       zero rewrites, for the same reason, from a real vendor binary.
#   E43a/E43  what the vendor stack DOES need. As shipped, two objects in one
#             driver stack bind two different implementations of five condvar
#             entry points. This turns that into one.
#   E44/E45   and what it needs more: on a real WSL host /usr/lib/wsl/lib is
#             reachable ONLY through /etc/ld.so.cache, which this ld.so is
#             patched to ignore. The symptom is not "cannot open library", it
#             is CUDA reporting no device at all.
#   E46       the vendor's own binary, driving the whole path itself.
echo
echo "-- F. a closed-source vendor driver, on real hardware -------------"
GPU_CASES="E41 E41b E41c E42 E43a E43 E44 E45 E46 E46a"
gpu_skip() { for id in $GPU_CASES; do skip "$id" "$1"; done; }

CUDA=/usr/lib/wsl/lib/libcuda.so.1
if [ ! -e /dev/dxg ]; then
    gpu_skip "no /dev/dxg: this host publishes no WSL GPU paravirtualisation device"
elif [ ! -f "$CUDA" ]; then
    gpu_skip "no $CUDA: the WSL driver userspace is not bind-mounted into this container"
else
    WSLLIB=$(dirname "$CUDA")
    # Read the floor out of the file rather than restating it. This greps the
    # whole binary, not DT_VERNEED, so it is informational only: the verdict
    # about what actually had to be rewritten is E42, which asks the loader.
    # Alpine's base image has neither binutils nor python, so grep it is.
    echo "  vendor driver : $CUDA"
    echo "  GLIBC version names anywhere in the file: $(grep -ao 'GLIBC_[0-9.]*' "$CUDA" | sort -u | tr '\n' ' ')"

    # E41: the whole point. Load a closed-source vendor blob under the
    # AppImage's own glibc, then push 4 KiB to the GPU and read it back. A
    # handle would only prove ld.so was satisfied.
    use_preload patched
    run E41  OK "round-tripped through the GPU and verified" \
        under_at 1 "$WSLLIB" /w/build/cudaprobe "$CUDA"

    # E41b: the control, and the finding. Everything else in this suite has a
    # control that FAILS. This one does not, and that is the answer rather than
    # a defect in the test: a GLIBC_2.2.5 floor cannot be missing anything, so
    # the feature has nothing to do. What is being measured here is that
    # turning it on does not break a driver that already worked.
    #
    # Note what =0 does NOT switch off. The preload is still loaded, so
    # version-compat.c is still interposing (E23), and this pair therefore says
    # nothing about the version-binding half. E43a is the control for that
    # half, and it uses upstream's shim, which has no forwarders at all.
    run E41b OK "round-tripped through the GPU and verified" \
        under_at 0 "$WSLLIB" /w/build/cudaprobe "$CUDA"

    # E41c: the strongest form of the same finding, and the one E41b cannot
    # make. NO preload in the process at all -- not this repo's, not
    # upstream's -- so no interception, no shim and no version-compat
    # forwarders. The vendor blob still drives the GPU. That is what "it never
    # needed the fix" means, stated so that nothing has to be taken on trust.
    run E41c OK "round-tripped through the GPU and verified" \
        env APPDIR="$APPDIR" "$LD" --library-path "$LP:$WSLLIB" \
        /w/build/cudaprobe "$CUDA"

    # E42: and it did not rewrite anything to get there. Same rule as E39,
    # arriving from a vendor binary instead of a synthetic probe.
    rm -f "$XDG_RUNTIME_DIR"/.cross-libc-dlopen-* 2>/dev/null
    ctrace=$(env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 \
             "$LD" --library-path "$LP:$WSLLIB" --preload "$LP/foreign-dlopen.so" \
             /w/build/cudaprobe "$CUDA" 2>&1)
    crw=$(printf '%s' "$ctrace" | grep -c 'cross-libc-dlopen: rewriting')
    ckept=$(printf '%s' "$ctrace" | grep -c 'needs no rewrite')
    [ "$crw" -eq 0 ] && [ "$ckept" -gt 0 ] && r42=1 || r42=0
    verdict E42 "$r42" "vendor blob: $crw object(s) rewritten, $ckept left unchanged (zero is the right answer)"

    # E43a/E43: which DEFINITION each object bound, read out of the process
    # rather than inferred. LD_BIND_NOW because a lazily-bound slot still holds
    # the PLT stub; it changes when the choice is made, never which definition
    # is chosen.
    CONDS="pthread_cond_wait pthread_cond_init pthread_cond_signal"
    CONDS="$CONDS pthread_cond_broadcast pthread_cond_destroy pthread_cond_timedwait"
    use_preload upstream
    run E43a FAIL "BINDINGS MIXED" env LD_BIND_NOW=1 CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 \
        APPDIR="$APPDIR" "$LD" --library-path "$LP:$WSLLIB" \
        --preload "$LP/foreign-dlopen.so" \
        /w/build/bindprobe "$CUDA" --init cuInit $CONDS
    use_preload patched
    run E43  OK "BINDINGS UNIFORM" env LD_BIND_NOW=1 CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 \
        APPDIR="$APPDIR" "$LD" --library-path "$LP:$WSLLIB" \
        --preload "$LP/foreign-dlopen.so" \
        /w/build/bindprobe "$CUDA" --init cuInit $CONDS

    # E44: the discovery gap, with nothing but the AppImage's own library path.
    # libcuda.so.1 opens by absolute path and loads fine; it is the BARE SONAME
    # dlopen("libdxcore.so") from inside it that cannot be resolved, and the
    # error surfaces as CUDA_ERROR_NO_DEVICE (100). A user reads that as "no
    # GPU", not as a missing library, which is what makes it worth a case.
    run E44 FAIL "FAILED: cuInit" under_at 1 "" /w/build/cudaprobe "$CUDA"

    # E45: and the fix for it, which is not in this repository. On a real WSL
    # host the directory IS discoverable -- WSL writes /etc/ld.so.conf.d/
    # ld.wsl.conf itself, verbatim as reproduced below -- so a launcher that
    # reads the plain-text conf finds it without touching the binary cache that
    # caused the segfault the cache patch exists for. That is exactly what
    # host_library_dirs() in patches/sharun-library-path.patch computes; the
    # derivation here is a shell stand-in for it, in a THROWAWAY container, and
    # no host file is touched (section 7).
    mkdir -p /etc/ld.so.conf.d
    printf '# generated by WSL, reproduced from the real file on this machine\n/usr/lib/wsl/lib\n' \
        > /etc/ld.so.conf.d/ld.wsl.conf
    [ -f /etc/ld.so.conf ] || printf 'include /etc/ld.so.conf.d/*.conf\n' > /etc/ld.so.conf
    CONFDIRS=$(conf_dirs)
    echo "  /etc/ld.so.conf names: $CONFDIRS"
    case ":$CONFDIRS:" in
        *":$WSLLIB:"*)
            run E45 OK "round-tripped through the GPU and verified" \
                under_at 1 "$CONFDIRS" /w/build/cudaprobe "$CUDA" ;;
        *)  skip E45 "the conf-derived path does not contain $WSLLIB, so this would not be measuring the patch" ;;
    esac

    # E46: the vendor's own binary. cudaprobe is ours; nvidia-smi is theirs, it
    # dlopens libnvidia-ml.so.1 by itself, and on Alpine it cannot run at all
    # without the AppImage's runtime -- musl's ld.so will not load a glibc
    # executable. That last part is the control this section otherwise lacks.
    if [ -x "$WSLLIB/nvidia-smi" ]; then
        run E46 OK "GPU 0:" under_at 1 "$WSLLIB" "$WSLLIB/nvidia-smi" -L
        # E46a: the same binary with no AppImage runtime under it. LD_LIBRARY_PATH
        # stands in for the /etc/ld.so.cache entry WSL writes, so this measures
        # the LOADER and not the discovery gap E44 already covers -- without it
        # the glibc host fails for E44's reason and says nothing about libc.
        nat=$(env LD_LIBRARY_PATH="$WSLLIB" "$WSLLIB/nvidia-smi" -L 2>&1); nrc=$?
        natline=$(printf '%s' "$nat" | tr '\n' ' ' | cut -c1-58)
        if [ "$HOSTLIBC" = musl ]; then
            # It must fail, and fail for the RIGHT reason. A missing library is
            # also non-zero, and that would be E44's finding rather than this
            # one, so both loaders' shared-library wording is excluded by name.
            if printf '%s' "$nat" | grep -qiE 'loading shared librar'; then
                why=lib
            else
                why=loader
            fi
            [ "$nrc" -ne 0 ] && [ "$why" = loader ] && r46=1 || r46=0
            verdict E46a "$r46" "musl host: the same binary does not run without the AppImage runtime -- $natline"
        else
            printf '%s' "$nat" | grep -q 'GPU 0:' && r46=1 || r46=0
            verdict E46a "$r46" "glibc host: it also runs natively, as it should -- $natline"
        fi
    else
        skip E46 "no $WSLLIB/nvidia-smi"
        skip E46a "depends on E46"
    fi
fi

# ---------------------------------------- G. the cross-libc ABI, at last
#
# T1.3 - T1.7 were SKIPPED and UNVERIFIED for the whole project. Every other
# result here says a host object LOADS and RUNS; these ask whether the data
# passing between it and the process means the same thing on both sides.
#
# The guest is one source file built twice: by glibc on the floor (E47, the
# control) and by musl on Alpine (E48/E49). Under the bundled glibc 2.44 the
# musl build is loaded through cross-libc-dlopen itself, which is what drops its
# libc edge -- no patchelf, no stand-in, the real code path.
echo
echo "-- G. cross-libc ABI: does the DATA mean the same on both sides? ---"
if [ ! -x /w/build/abi-host ]; then
    skip E47 "abi-host was not built on the floor"
    skip E48 "depends on E47"; skip E49 "depends on E47"; skip E50 "depends on E47"
else
    # E47: same libc on both sides. Establishes that the 27 checks can pass at
    # all, so a musl-side failure is attributable to the crossing.
    run E47 OK "ABI CROSSING PASSED" under 1 /w/build/abi-host \
        /w/build/libabi_glibc.so glibc

    if [ ! -f /w/build/libabi_musl.so ]; then
        skip E48 "no musl-built guest in /w/build: run 45-build-musl-guest.sh first"
        skip E49 "depends on E48"; skip E50 "depends on E48"
    else
        # E48: the control that FAILS. With the feature off the bundled ld.so
        # goes looking for musl's soname and does not find it, which is what
        # makes E49 a measurement rather than a coincidence. ⛔ The needle is
        # $MUSL_SO, not a literal: the guest is built on Alpine for THIS
        # architecture, so on aarch64 the name it fails to find is
        # libc.musl-aarch64.so.1 and a hardcoded needle would never match.
        run E48 FAIL "$MUSL_SO" under 0 /w/build/abi-host \
            /w/build/libabi_musl.so musl
        # E49: and with it on, every crossing holds -- allocator, errno, FILE*,
        # mutex and condvar -- with one libc in the process.
        run E49 OK "ABI CROSSING PASSED" under 1 /w/build/abi-host \
            /w/build/libabi_musl.so musl

        # E50: and the part no loader can fix, stated as a number rather than
        # left as a worry. The guest's compiled-in offsets and constants are
        # its own; where they disagree with glibc's, a musl object reads the
        # wrong field out of a struct glibc filled. Two of the six hazards
        # REPORT.md listed turn out to be live and the rest benign, and this
        # case fails if that ever stops being true.
        # The names come out of the same run as the count. Hardcoding them
        # beside a measured number is how a report ends up describing a
        # different result from the one it counted.
        hazout=$(under 1 /w/build/abi-host /w/build/libabi_musl.so musl 2>&1)
        haz=$(printf '%s' "$hazout" | grep -c 'LIVE HAZARD')
        hazwhat=$(printf '%s' "$hazout" | grep -E '^ *DIFF ' |
                  sed 's/^ *DIFF  *//; s/  */ /g; s/ host=.*//' | tr '\n' ';')
        [ "$haz" -eq 2 ] && r50=1 || r50=0
        verdict E50 "$r50" "reading back a glibc-filled struct: $haz live hazard(s) -- ${hazwhat:-none}"
    fi
fi

# ------------------------------- H. Design R, with a real device on the end
#
# The OTHER half of the design, and until now the untested one. E17-E21 show
# the selector CHOOSING correctly on eight distros and refusing the mixed set
# that segfaults; none of them puts a driver on the end of the choice.
#
# Read these beside E31 and E32 on the same host. All three run the same host
# ICD, and they differ only in how the process got a libc it can satisfy:
#
#   E31  bundled runtime, feature off            no devices
#   E32  bundled runtime, feature on             1 device   (the shim half)
#   E51  host runtime, no feature at all         1 device   (the Design R half)
#
# The switch is FORCED here. Auto declines on this host and is right to: the
# bundled glibc is newer than the host's, so there is nothing to gain and a
# switch would only lose. What is being measured is whether the switched
# runtime can drive a real device, not whether it should have been chosen.
echo
echo "-- H. Design R: the host runtime, with a driver on the end --------"
RSEL=/w/build/runtime-select
if [ "$HAVE_VK" = no ]; then
    vk_skip E51 E52
elif [ ! -x "$RSEL" ]; then
    skip E51 "runtime-select was not built on the floor"
    skip E52 "depends on E51"
elif [ "$HOSTLIBC" = musl ]; then
    skip E51 "musl host: there is no host GLIBC runtime set to switch to, which is why Design R declines here and the shim half is the only one available"
    skip E52 "musl host: as E51"
else
    plan=$(env APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_RUNTIME=host "$RSEL" --probe 2>&1)
    if ! printf '%s' "$plan" | grep -q 'runtime      : host'; then
        why=$(printf '%s' "$plan" | sed -n 's/^reason *: //p' | cut -c1-90)
        skip E51 "this host's runtime set was refused, correctly: $why"
        skip E52 "depends on E51"
    else
        printf '  %s\n' "$(printf '%s' "$plan" | sed -n 's/^library-path : //p' | cut -c1-150)"
        # E51: a graphics driver through the switched runtime. No preload, no
        # CROSS_LIBC_DLOPEN: the host ICD's own dependencies resolve
        # because the host library directories are on the path, which is the
        # whole of what Design R does.
        run E51 OK "OK: 1 physical device" \
            env APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_RUNTIME=host "$RSEL" -- /w/build/vkprobe
        # E52: and the same through to real silicon. This needs
        # /usr/lib/wsl/lib on the path, which the selector now derives from
        # /etc/ld.so.conf -- the file E45 put in place, verbatim from a real
        # WSL distro, and the same computation the sharun patch does.
        if [ -e /dev/dxg ] && [ -f "$CUDA" ]; then
            run E52 OK "round-tripped through the GPU and verified" \
                env APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_RUNTIME=host "$RSEL" -- \
                /w/build/cudaprobe "$CUDA"
        else
            skip E52 "no /dev/dxg with a WSL vendor driver on this host"
        fi
    fi
fi

# --------------------------------- I. rendering on hardware, for the first time
#
# Every rendering result above this line is Mesa lavapipe or llvmpipe: software
# rasterisers that exercise the identical dlopen path and draw every pixel on
# the CPU. "No GPU" was the standing caveat of the whole project.
#
# It was wrong for a second reason. WSL2 publishes no DRM render node, so radv,
# anv and radeonsi cannot initialise -- but Mesa's d3d12 GALLIUM driver does not
# need one. It talks to /dev/dxg through Microsoft's libdxcore, and Debian
# packages it as dri/d3d12_dri.so. That makes the host's own OpenGL driver a
# hardware driver, and the AppImage's bundled libglvnd has a real vendor library
# to dlopen at last.
#
# E53a is the third independent sighting of one bug. The AppImage fails on this
# driver with `glXCreateContext failed`, which reads like a display or driver
# fault and is neither: d3d12_dri.so dlopens libd3d12.so by BARE SONAME, sharun
# assembles the only search path there is, and its host-GPU directory list is
# hardcoded -- /run/opengl-driver/lib and /run/current-system/sw/lib are on it,
# /usr/lib/wsl/lib is not. E44 is the same bug in CUDA and E52 is the same bug
# in Design R. All three are what patches/sharun-library-path.patch computes.
echo
echo "-- I. the host's GL driver on REAL hardware ------------------------"
D3D12=$(ls /usr/lib/*/dri/d3d12_dri.so /usr/lib/dri/d3d12_dri.so 2>/dev/null | head -1)
if [ ! -e /dev/dxg ]; then
    skip E53a "no /dev/dxg: nothing here can reach a GPU"
    skip E53  "no /dev/dxg"; skip E53b "no /dev/dxg"
elif [ -z "$D3D12" ]; then
    skip E53a "no dri/d3d12_dri.so on this host: its Mesa has no Vulkan-or-GL-on-D3D12 driver, so /dev/dxg cannot become a GL device"
    skip E53  "as E53a"; skip E53b "as E53a"
elif ! command -v xvfb-run >/dev/null 2>&1; then
    skip E53a "no xvfb-run on this host: install xvfb"
    skip E53  "as E53a"; skip E53b "as E53a"
elif ! ls /usr/lib/libGLX_*.so.0 >/dev/null 2>&1 && ! ls /usr/lib/*/libGLX_*.so.0 >/dev/null 2>&1; then
    skip E53a "no libGLX_<vendor>.so.0 on this host; its Mesa is not libglvnd, so the bundled libglvnd has no vendor to dlopen"
    skip E53  "as E53a"; skip E53b "as E53a"
else
    echo "  host GL driver : $D3D12"
    HOSTDIRS=$(conf_dirs)
    # E53a: the AppImage exactly as it stands, on the hardware driver.
    run E53a OK "glXCreateContext failed" render_verdict_hw 1 "" glxgears -info
    # E53: the same command with the directories the host's own ld.so.conf
    # names handed to sharun through its own fallback knob -- no file edited,
    # nothing patched, exactly what the patch would have computed.
    run E53  OK "GL_RENDERER   = D3D12" render_verdict_hw 1 "$HOSTDIRS" glxgears -info
    # E53b: and the A/B, which does NOT flip. The host GL stack here is
    # glibc-built against an older glibc than the bundle, so there is nothing
    # for the shim to do -- the same result as E41b and for the same reason.
    # What E53 measures is hardware, not the shim; saying otherwise would be
    # claiming a control that did not happen.
    run E53b OK "GL_RENDERER   = D3D12" render_verdict_hw 0 "$HOSTDIRS" glxgears -info
fi

# Leave the AppDir holding the patched preload, so a later run that starts
# mid-suite is not silently measuring upstream's.
use_preload patched

# --------------------------------- J. the OTHER boundary: a bundled DISPATCHER
#
# Everything above measures ONE boundary. The bundled Vulkan loader dlopens the
# host's ICD; the ICD was built against another libc; cross-libc-dlopen.so carries
# it across. That is a LIBC gap, and the host had the thing all along.
#
# The AppDir contains eight other objects that dlopen something (E59), and one
# of them fails a different way. libglvnd's libGL.so.1 is a DISPATCHER: it
# dlopens a VENDOR library, libGLX_<vendor>.so.0, and a host whose Mesa was
# built without glvnd does not ship one AT ALL. No amount of libc bridging can
# carry a file that does not exist. That is an INTERFACE gap, and the repair is
# a different one: replace the bundled dispatcher (src/gl-fwd.c).
#
# This section was previously one line -- E38, SKIPPED, with the reason "that
# gap is host packaging, not libc" and the verdict "not fixable from a loader
# shim". The reason was true. The verdict was never tested, and it was wrong.
echo
echo "-- J. OpenGL: replacing a dispatcher whose vendor the host lacks ---"

# Which class of host is this? The bundled dispatcher needs a vendor library;
# if the host has one it works as shipped, and the shim's job is to be
# invisible. If not, the shim is the only thing that makes GL work at all.
# Each glob is tested separately: `ls a b` fails as a whole when either misses.
if ls /usr/lib/libGLX_*.so.0 >/dev/null 2>&1 || ls /usr/lib/*/libGLX_*.so.0 >/dev/null 2>&1; then
    GLHOST=glvnd
else
    GLHOST=classic
fi
echo "  host GL stack: $GLHOST$([ $GLHOST = classic ] && echo ' (no libGLX_<vendor>.so.0 anywhere)')"

# The .preload file drives which shims the AppRun loads. Restore it from the
# copy 41-extract.sh kept, so a case whose whole point is the shim's ABSENCE
# cannot silently run with it present.
use_gl_shims() {               # use_gl_shims [gl] [egl]
    cp "$APPDIR/.preload.shipped" "$APPDIR/.preload"
    rm -f "$LP/gl-fwd.so" "$LP/egl-fwd.so"
    for s in "$@"; do
        case "$s" in
            gl)  cp /w/build/gl-fwd.so  "$LP/gl-fwd.so";  echo gl-fwd.so  >> "$APPDIR/.preload" ;;
            egl) cp /w/build/egl-fwd.so "$LP/egl-fwd.so"; echo egl-fwd.so >> "$APPDIR/.preload" ;;
        esac
    done
}

# A GL binary never exits on its own, so `timeout` kills xvfb-run and leaves
# the child holding the stdout pipe: a $( ) capture then hangs forever ON THE
# CASE THAT WORKED. Write to a file and reap instead. glprobe and eglprobe do
# exit, which is most of why they exist.
gl_run() {                     # gl_run <keep-exit-code:0|1> <binary> [args...]
    keep="$1"; shift
    : > /tmp/gl_case.out
    # GLPATH is EMPTY on every host that does not need it, and that is not a
    # detail: handing sharun the host's library directories changes what the
    # NO-SHIM controls (E61, E63, E65) do. Measured -- with the host dirs on
    # the path, glxgears renders on Alpine with no shim at all, through the X
    # server's own softpipe GLX, and E61 stops being a control for anything.
    # So the directories are added only where a pre-flight showed the host's
    # driver cannot load without them, and the pre-flight prints its answer.
    env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" LIBGL_ALWAYS_SOFTWARE=1 \
        EGL_PLATFORM=surfaceless SHARUN_FALLBACK_LIBRARY_PATH="$GLPATH" \
        timeout -k 2 30 xvfb-run -a -s "$XA" "$APPDIR"/AppRun.sh "$@" \
        > /tmp/gl_case.out 2>&1 </dev/null
    rc=$?
    pkill -9 glxgears 2>/dev/null; pkill -9 Xvfb 2>/dev/null
    rm -f /tmp/.X*-lock 2>/dev/null
    # A probe states its verdict on a line of its OWN, and that line comes
    # first. Reaching for GL_RENDERER ahead of it is how a 33-of-3470 shim
    # scores a pass: it prints a renderer and dies two calls later on a symbol
    # the renderer line says nothing about.
    grep -m1 -E '^(OK|FAILED)' /tmp/gl_case.out ||
    grep -m1 -E 'Selected GPU|GL_RENDERER|couldn.t get|undefined symbol|EGL_NO_DISPLAY' \
        /tmp/gl_case.out ||
    echo "no recognisable output"
    [ "$keep" = 1 ] && return $rc
    return 0
}
# The probes exit, so their status IS the measurement.
gl_verdict() { gl_run 1 "$@"; }
# glxgears never exits, and vkcube exits 0 whether or not it found a device, so
# for those the exit code carries nothing and only the output does. Predicting
# on it would score the timeout that ENDS a successful render as a failure.
gl_render() { gl_run 0 "$@"; }

# Both tools are written in modern Python. Asked by VERSION rather than by
# running them, because a SyntaxError from an f-string on python3.4 arrives as
# a non-zero exit with a traceback, which the harness would score as a finding
# about the AppDir. Neither case is host-dependent -- they measure the bundle
# and the checked-in table -- so skipping them on an old host loses nothing
# that the other hosts do not already establish.
PY_OK=no
command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)' 2>/dev/null &&
    PY_OK=yes
if [ "$PY_OK" = no ]; then
    PYV=$(python3 -V 2>&1 | tr -d '\n')
    skip E59 "${PYV:-no python3} on this host: the boundary scan needs python 3.6+ (both cases measure the BUNDLE, not the host, and hold from the other hosts)"
    skip E60 "as E59"
else
    # E59: every bundled object that imports dlopen is classified. An
    #      UNCLASSIFIED one is a boundary nobody has looked at, which is exactly
    #      how the OpenGL gap survived a whole session with a SKIP on it.
    run E59 OK "UNCLASSIFIED 0" python3 /repo/tools/plugin_boundaries.py "$APPDIR" --check
    # E60: the forwarding tables are read out of the bundled libglvnd, so a
    #      newer bundled libglvnd with a new entry point must not go unnoticed:
    #      the shim would export less than the object it replaces.
    run E60 OK "matches" sh -c \
        "cd /repo/src && python3 /repo/tools/gen_gl_fwd.py $LP/libGL.so.1 \
             --prefix gl --soname libGL.so.1 --check gl-fwd-gl.h"
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
    for c in E61 E62 E63 E64 E65 E66 E67 E68 E74 E74b E77 E78 E79; do skip $c "no xvfb-run on this host"; done
elif [ ! -f /w/build/gl-fwd.so ] || [ ! -f /w/build/glprobe ]; then
    for c in E61 E62 E63 E64 E65 E66 E67 E68 E74 E74b E77 E78 E79; do
        skip $c "gl-fwd.so or glprobe was not built on the floor"
    done
else
    # The probes have to run the way the AppImage's own binaries do -- through
    # sharun, under the bundled loader, with the .preload applied -- or they are
    # measuring a different process from the one under test. sharun dispatches
    # on the name it was invoked as, so a copy of it in bin/ with the probe's
    # name and the real binary in shared/bin/ is the whole installation.
    for p in glprobe eglprobe; do
        cp "/w/build/$p" "$APPDIR/shared/bin/$p"
        cp "$APPDIR/sharun" "$APPDIR/bin/$p" 2>/dev/null ||
            ln -sf ../sharun "$APPDIR/bin/$p"
    done

    # ---- E77: does this host's GL driver need directories the AppDir lacks?
    #
    # Asked by RUNNING it, once, before anything is predicted, because the
    # answer is a property of how the host packages its own driver and cannot
    # be read off a file. Ubuntu 16.04's swrast_dri.so needs libLLVM-6.0.so.1,
    # which is reachable there only through /etc/ld.so.cache -- and the bundled
    # ld.so is patched not to read the cache (E13b). What the user sees is
    # `libGL error: unable to load driver: swrast_dri.so` and then an X error
    # from glXCreateContext: a display fault, apparently. It is the same bug as
    # CUDA_ERROR_NO_DEVICE in E44 and `glXCreateContext failed` in E53a, and
    # this is its fourth sighting.
    #
    # What is SCORED is the diagnostic, not the outcome. The outcome differs by
    # host and neither answer is wrong; the claim that holds everywhere is that
    # when this bites, the process names the library it could not find -- never
    # a missing symbol, never silence.
    GLPATH=""
    use_gl_shims gl
    : > /tmp/nopath.out
    env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 \
        LIBGL_ALWAYS_SOFTWARE=1 EGL_PLATFORM=surfaceless \
        SHARUN_FALLBACK_LIBRARY_PATH="" \
        timeout -k 2 30 xvfb-run -a -s "$XA" "$APPDIR"/AppRun.sh glprobe \
        > /tmp/nopath.out 2>&1 </dev/null
    npc=$?
    pkill -9 Xvfb 2>/dev/null; rm -f /tmp/.X*-lock 2>/dev/null
    if [ "$npc" -eq 0 ]; then
        verdict E77 1 "this host's GL driver needs nothing outside the bundle; no directories added"
    elif grep -qE 'unable to load driver|failed to load driver|cross-libc dlopen failed' /tmp/nopath.out; then
        GLPATH=$(conf_dirs)
        verdict E77 1 "the host driver cannot load from the AppDir's path alone and the process NAMES it -- $(grep -m1 -oE '(unable|failed) to load driver: [^ ]*' /tmp/nopath.out); adding the dirs /etc/ld.so.conf gives"
    else
        verdict E77 0 "it failed without the host dirs and named no library: $(tr '\n' ' ' < /tmp/nopath.out | cut -c1-70)"
    fi

    # ---- E78/E79: the NATIVE control, and what E64/E66 are predicted against
    #
    # The shim's claim is TRANSPARENCY: an application gets what the host's own
    # GL and EGL would have given it. So the yardstick is the host, not a
    # constant -- and predicting "OK" everywhere is how the suite ended up
    # calling Ubuntu 16.04 a MISMATCH for something that fails there with no
    # AppImage in the process at all:
    #
    #   native eglprobe on ubuntu:16.04, no shim, no preload, no AppDir
    #     EGL_VERSION : 1.4   EGL_VENDOR : Mesa Project
    #     readback rgba : 0 0 0 255 (want ~64 128 191 255)
    #     FAILED: the pixel does not carry the colour that was set
    #
    # Mesa 18.0.5 does not produce that pixel on this host at all. A shim that
    # then produced it would be inventing one. So E64 and E66 predict THE
    # NATIVE RESULT, and where the host cannot be asked -- no compiler, no
    # headers -- they fall back to the per-host-class prediction and say so.
    NGL_WANT=OK;  NGL_NEEDLE="OK: GL is complete"
    NEGL_WANT=OK; NEGL_NEEDLE="OK: EGL is complete"
    NATIVE=none
    if command -v gcc >/dev/null 2>&1 &&
       gcc -O2 -o /tmp/native-glprobe  /repo/tests/glprobe.c  -lGL -lX11 2>/dev/null &&
       gcc -O2 -o /tmp/native-eglprobe /repo/tests/eglprobe.c -lEGL -lGL 2>/dev/null; then
        NATIVE=built
        native_run() {         # native_run <binary>
            : > /tmp/native.out
            # The SAME environment gl_run uses, minus the AppImage. A control
            # run under different conditions from the case it controls is not a
            # control: EGL_PLATFORM alone decides whether Mesa 18.0.5 answers at
            # all, so leaving it out here would have the native run pass and the
            # shimmed run fail for a reason neither of them is about.
            env LIBGL_ALWAYS_SOFTWARE=1 EGL_PLATFORM=surfaceless \
                timeout -k 2 40 xvfb-run -a -s "$XA" \
                "$1" > /tmp/native.out 2>&1 </dev/null
            nrc=$?
            pkill -9 Xvfb 2>/dev/null; rm -f /tmp/.X*-lock 2>/dev/null
            grep -m1 -E '^(OK|FAILED)' /tmp/native.out || echo "no verdict line"
            return $nrc
        }
        # E78/E79 are the controls, and they are scored: a control nobody
        # checks is a control that can quietly stop running.
        # ⛔ What E78 and E79 assert is that the control RAN, not that it
        # passed. Either answer is a legitimate property of a host -- 16.04's
        # native EGL fails -- but "it printed no verdict at all" is neither,
        # and it is the dangerous one: a native probe that cannot reach a
        # display relaxes E64's prediction to FAIL, and a completely broken
        # shim then scores MATCH for failing too. A control that is allowed to
        # be absent is a control that silently stops controlling.
        nout=$(native_run /tmp/native-glprobe); nrc=$?
        # The verdict line and the exit status must AGREE. A probe that says
        # OK and exits non-zero has not finished, which is the shape section 5
        # records for GL_RENDERER, and neither half of it should be believed.
        case "$nout,$nrc" in
            OK:*,0)      NGL_WANT=OK;   NGL_NEEDLE="OK: GL is complete"; n78=1 ;;
            FAILED*,0)   n78=0 ;;
            FAILED*)     NGL_WANT=FAIL; NGL_NEEDLE="FAILED";             n78=1 ;;
            *)           n78=0 ;;   # keeps the host-class default, and MISMATCHes
        esac
        verdict E78 "$n78" "native glprobe (no AppImage at all), rc=$nrc: $(printf '%s' "$nout" | cut -c1-60)"
        nout=$(native_run /tmp/native-eglprobe); nrc=$?
        case "$nout,$nrc" in
            OK:*,0)      NEGL_WANT=OK;   NEGL_NEEDLE="OK: EGL is complete"; n79=1 ;;
            FAILED*,0)   n79=0 ;;
            FAILED*)     NEGL_WANT=FAIL; NEGL_NEEDLE="FAILED";              n79=1 ;;
            *)           n79=0 ;;
        esac
        verdict E79 "$n79" "native eglprobe (no AppImage at all), rc=$nrc: $(printf '%s' "$nout" | cut -c1-60)"
        echo "         E64 and E66 are therefore predicted GL=$NGL_WANT EGL=$NEGL_WANT on this host"
    else
        skip E78 "no gcc or no GL/EGL headers on this host: the native control cannot be built, so E64 and E66 fall back to predicting the host CLASS rather than this host"
        skip E79 "as E78"
    fi
    # E61/E62: glxgears, the case the README recorded as not done. On a classic
    #          host E61 is the failure users report; on a glvnd host it already
    #          worked and E61 says so, which is what makes E62 a regression test
    #          rather than a repeat.
    use_gl_shims
    if [ "$GLHOST" = classic ]; then
        run E61 OK "couldn't get an RGB" gl_render glxgears -info
    else
        run E61 OK "GL_RENDERER" gl_render glxgears -info
    fi
    use_gl_shims gl
    run E62 OK "GL_RENDERER" gl_render glxgears -info

    # E63/E64: glxgears links 33 of the 3470 entry points libGL.so.1 exports, so
    #          a shim written to make glxgears run passes E62 and nothing else.
    #          glprobe calls past that set AND reads a pixel back, which is the
    #          difference between "the symbol existed" and "the call arrived".
    use_gl_shims
    if [ "$GLHOST" = classic ]; then
        run E63 FAIL "FAILED: no RGB double-buffered visual" gl_verdict glprobe
    else
        run E63 OK "OK: GL is complete" gl_verdict glprobe
    fi
    use_gl_shims gl
    run E64 "$NGL_WANT" "$NGL_NEEDLE" gl_verdict glprobe

    # E65/E66: EGL is the same dispatcher shape with a different vendor marker
    #          (a JSON directory, not a libGLX_*.so.0), and it is INDEPENDENT:
    #          the GL shim alone does not fix it, which is the measurement that
    #          says these really are two boundaries and not one.
    use_gl_shims gl
    if [ "$GLHOST" = classic ]; then
        run E65 FAIL "FAILED: eglGetDisplay" gl_verdict eglprobe
    else
        run E65 OK "OK: EGL is complete" gl_verdict eglprobe
    fi
    use_gl_shims gl egl
    run E66 "$NEGL_WANT" "$NEGL_NEEDLE" gl_verdict eglprobe

    # E67: and none of it costs the Vulkan path anything. The shims are
    #      preloaded for every binary in the AppDir, vkcube included.
    #
    # ⚠ This is a VULKAN case living in the OpenGL section, which is exactly
    # how it got missed when the pre-glvnd glibc hosts were added: Mesa 10.1
    # predates Vulkan, vkcube found no device, and the case reported MISMATCH
    # for a capability the host does not have rather than SKIPPED for it. A
    # case whose section is not the same as its dependency needs the guard
    # written where the case is, not where the section is.
    if [ "$HAVE_VK" = no ]; then
        vk_skip E67
    else
        run E67 OK "Selected GPU" gl_render vkcube --c 20
    fi

    # E68: the shim carries the SONAME it impersonates, so anything that
    #      resolves that name back to the shim would make every trampoline jump
    #      to itself -- unbounded recursion inside the first GL call, with a
    #      stack overflow for a diagnostic. Pointed straight at itself here, it
    #      says so and leaves the table absent, and the application gets its own
    #      documented failure instead. A guard that has never been fired is a
    #      guard nobody knows the shape of.
    use_gl_shims gl
    mkdir -p /tmp/glfwd-self
    ln -sf "$LP/gl-fwd.so" /tmp/glfwd-self/libGL.so.1
    : > /tmp/gl_case.out
    env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 \
        CROSS_LIBC_DLOPEN_GL_HOST_DIR=/tmp/glfwd-self CROSS_LIBC_DLOPEN_GL_TARGET=host \
        timeout -k 2 30 xvfb-run -a -s "$XA" "$APPDIR"/AppRun.sh glprobe \
        > /tmp/gl_case.out 2>&1 </dev/null
    rc=$?
    pkill -9 Xvfb 2>/dev/null; rm -f /tmp/.X*-lock 2>/dev/null
    if [ "$rc" -ne 0 ] && grep -q "refusing to forward to ourselves" /tmp/gl_case.out; then
        verdict E68 1 "self-forward refused by name, and the app got its own failure"
    else
        verdict E68 0 "self-forward guard did not fire (rc=$rc)"
    fi

    # E74/E74b: what the shims cost a process that never draws. The old
    #      constructor loaded the host GL stack in EVERY process that had the
    #      shims in .preload, Vulkan-only ones included -- 30 MB of host Mesa
    #      mapped into something that would never call it (REPORT.md 9.9).
    #      Nothing resolves until something calls now, and this is that claim at
    #      AppImage scale rather than in the four-symbol object E71 uses.
    #      Both sides, because "no GL was loaded" is also what a broken shim
    #      would produce: E74b is the same command after a GL call.
    use_gl_shims gl egl
    vkout=$(env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 APPDIR="$APPDIR" \
            "$LD" --library-path "$LP" --preload "$LP/foreign-dlopen.so $LP/gl-fwd.so $LP/egl-fwd.so" \
            /w/build/vkprobe 2>&1)
    if printf '%s' "$vkout" | grep -q 'entry points resolved'; then
        verdict E74 0 "a Vulkan-only run still resolved the GL stack"
    else
        verdict E74 1 "Vulkan-only run: $(printf '%s' "$vkout" | grep -c 'loads at the first GL call') shim(s) loaded, 0 resolved, no host GL mapped"
    fi
    : > /tmp/gl_case.out
    # The same environment gl_run uses, GLPATH included. Without it this run
    # fails on a host that needs the host dirs, and the "how many entry points
    # were CALLED" line below then reports the three calls of a FAILING run as
    # if it were the application's real usage.
    env CROSS_LIBC_DLOPEN=1 ANYLINUX_LIB_FOREIGN_DLOPEN=1 APPDIR="$APPDIR" CROSS_LIBC_DLOPEN_DEBUG=1 ANYLINUX_LIB_DEBUG=1 \
        LIBGL_ALWAYS_SOFTWARE=1 EGL_PLATFORM=surfaceless \
        SHARUN_FALLBACK_LIBRARY_PATH="$GLPATH" \
        timeout -k 2 30 xvfb-run -a -s "$XA" \
        "$APPDIR"/AppRun.sh glprobe > /tmp/gl_case.out 2>&1 </dev/null
    pkill -9 Xvfb 2>/dev/null; rm -f /tmp/.X*-lock 2>/dev/null
    if grep -q 'entry points resolved' /tmp/gl_case.out; then
        verdict E74b 1 "the same shims, after a GL call: $(grep -m1 -o '[0-9]* of [0-9]* entry points resolved' /tmp/gl_case.out)"
    else
        verdict E74b 0 "a GL run did NOT resolve the stack, so E74 measures nothing"
    fi

    # How much of the dispatcher the host can actually stand behind, and how
    # much of it the application TOUCHED. Reported rather than asserted: the
    # first number is a property of the host's Mesa and the second of the
    # program, and a threshold on either would be a threshold on somebody
    # else's work.
    grep -m1 'entry points resolved' /tmp/gl_case.out |
        sed 's/^ *\[gl-fwd.so\] >> /         /'
    grep -m1 'entry points were CALLED' /tmp/gl_case.out |
        sed 's/^ *\[gl-fwd.so\] >> /         /'
    # And the names, when there are any: B1's whole point is that an absent
    # entry point an application actually reaches is now a line and not a zero.
    nab=$(grep -c 'ABSENT entry point called' /tmp/gl_case.out)
    if [ "$nab" -gt 0 ]; then
        echo "         absent entry points this application reached: $nab"
        grep -o 'ABSENT entry point called: [A-Za-z0-9_]*' /tmp/gl_case.out |
            sed 's/.*: /           /' | sort -u | head -8
    else
        echo "         absent entry points this application reached: 0"
    fi

    use_gl_shims
fi

echo
echo "================================================================"
echo " predictions matched: $PASS   mismatched: $FAIL   skipped: $SKIP"
echo "================================================================"
[ "$FAIL" -eq 0 ]
