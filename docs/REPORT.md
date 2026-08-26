# REPORT

What was built, what was measured, and what is still broken.

Every claim is either backed by a command whose output is quoted, or labelled
**UNVERIFIED**. Nothing is estimated.

---

## 1. Summary

| Goal | Status |
|---|---|
| A host GPU driver built against a **newer glibc** loads into a process carrying an older bundled glibc | **Achieved.** Two mechanisms: the generated shim (E5) and the host-runtime switch (E12, no shim at all). The selector picks correctly on 8 of 8 distros |
| A **musl-built** host driver loads into that same glibc process **and renders** | **Achieved.** On Alpine 3.22, the demo AppImage's bundled glibc 2.44 drives Alpine's musl-built lavapipe: `vkEnumeratePhysicalDevices` returns one device and `vkcube` renders (E32, E37). Exactly one libc family is mapped (E35). 60 s of continuous rendering with RSS, fds and threads flat. See section 6 |
| A **closed-source** host driver does the same, on real silicon | **Achieved, and it never needed the fix.** NVIDIA's `libcuda.so.1` loads under the bundled glibc on Alpine and round-trips 4096 bytes through an RTX 3050 Ti (E41) -- and so does the control, because a vendor ships against a `GLIBC_2.2.5` floor on purpose. What the vendor stack DID need is uniform version binding (E43a/E43). Section 7.1 |
| Rendering on an actual GPU rather than a software rasteriser | **Achieved for OpenGL.** `GL_RENDERER = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)` at 101-121 FPS through the AppImage with no file changed (E53), via Mesa's d3d12 Gallium driver, which needs no DRM render node. Vulkan is still lavapipe: `dzn` is not packaged. Section 7.5 |
| The cross-libc ABI microtests, T1.3-T1.7 | **Written and passing.** 26 crossings hold with a musl guest; of the six struct hazards, two are live and named and four are benign, measured rather than assumed. Section 7.4 |

| Completion criterion | Status |
|---|---|
| Both goals demonstrated by a test that fails before and passes after | **Yes.** Goal 1: E5, E12. Goal 2: E22/E23 for the mechanism, E30/E32 and E37a/E37 for the end-to-end |
| The evidence harness still reports all predictions held | **Yes, 53/53** on x86-64 and **50/50** on aarch64, up from 22/22. The AppImage suite adds 45 on a glvnd glibc host, 40 on musl, 26 on each of two pre-glvnd glibc hosts and 7 on a real-application stage, with every unrunnable case SKIPPED by the capability it lacks |
| No host file modified, verified by checksum | **Yes.** T4.3, identical sha256 before and after |
| Bundled libraries still win, verified via `dladdr` | **Yes.** T4.2, all resolved under `$APPDIR` |
| A forward-compatibility story that does not depend on foresight | **Yes.** Host-runtime selection for the unenumerable gap, a generated shim for the enumerable one, and a build-time audit (E26) for the version traps |
| A report separating measured from assumed | this document |

The one thing this report previously got wrong is worth stating plainly, because
it was the central claim: **the rendering failure was blamed on glibc-vs-musl
ABI differences, and it was not that.** Removing an object's symbol version
requirements is by itself enough to break it, on one libc, with no musl and no
Vulkan anywhere in the process. Section 6.2 is the measurement.

---

## 2. Environment reached

**Highest tier reached: Tier 5**, on hardware, for OpenGL and for compute. All
Tier 4 invariants run. Tier 3 end-to-end runs under `xvfb` with software Vulkan,
and Vulkan is the one path with no hardware result: Mesa's Vulkan-on-D3D12
driver is not packaged (section 7.5).

```
$ uname -srm                     # inside every test container
Linux 7.2.0-WSL2-STABLE x86_64

podman version 5.8.6             (WSL2 Fedora 44 machine)
Python 3.13                      (host, for the Tier-0 tooling)
```

| Image | libc | Role |
|---|---|---|
| `alpine:3.22` | musl 1.2.5 | the musl host, software Vulkan |
| `debian:bullseye-slim` | glibc 2.31 | "an AppImage bundling an older glibc", and the build host |
| `debian:trixie-slim` | glibc 2.41 | the newer-glibc build host |
| `ubuntu:20.04` | glibc 2.31 | no-regression check |
| `rockylinux:9` | glibc 2.35 | selector matrix |
| `fedora:44` | glibc 2.43 | selector matrix |
| `opensuse/tumbleweed` | glibc 2.43 | selector matrix |
| `archlinux:latest` | glibc 2.44 | selector matrix, newest released glibc |
| `ubuntu:14.04` | glibc 2.19 | pre-glvnd glibc host, Mesa 10.1.3, no Vulkan at all |
| `ubuntu:16.04` | glibc 2.23 | pre-glvnd glibc host, Mesa 18.0.5, no Vulkan at all |

⚠ The last two are served from `archive.ubuntu.com` at the DEFAULT path -- they
are still inside their ESM window -- and are **not** on
`old-releases.ubuntu.com`, which as of 2026-08 carries neither. The
`sources.list` rewrite every guide prescribes is what breaks them; what has to
go is the image's own ESM source, which needs credentials and makes apt fail
the whole update and then report every package as "unable to locate".

Software rendering is used for every Vulkan result and is named in each one:
Mesa **lavapipe** and **llvmpipe** (LLVM 20.1.8, 256 bits), pinned with
`VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json` so a half-working
host GPU could not silently take over.

Two GPUs are reachable and are used where a case says so: an NVIDIA GeForce
RTX 3050 Ti Laptop and an Intel Iris Xe, both through `/dev/dxg`
paravirtualisation with the vendor userspace bind-mounted from
`/usr/lib/wsl`. There is no `/dev/dri` on this machine at all, so `radv`, `anv`
and `radeonsi` cannot initialise; `d3d12` and CUDA do not need one. Cases that
require the device are SKIPPED with that capability named on a machine without
it, and the suite still passes.

The host driver is sane natively, so every downstream result is interpretable:

```
$ vulkaninfo --summary        # Alpine 3.22, native musl
        deviceName         = llvmpipe (LLVM 20.1.8, 256 bits)
        driverName         = llvmpipe
```

---

## 3. Six defects found by measurement

None of these were in the problem statement. Each was found by running
something, and each is fixed.

### 3.1 musl folds `libm` into `libc`; glibc splits it out

The known hazard was glibc's own 2.34 consolidation, where `libpthread`,
`libdl`, `librt`, `libutil` and `libanl` merged into `libc.so.6`, so a modern
build emits `pthread_create@GLIBC_2.34` with no `DT_NEEDED` on `libpthread`.
That is E6 and E7.

The mirror image is what actually blocked the musl case. musl keeps the maths,
threading and dynamic-linking functions **inside** `libc.musl-x86_64.so.1`. A
musl-built object therefore imports `fmod`, `fesetround`, `log10` and `pow`
with no `DT_NEEDED` on anything, because on musl its libc edge covered them,
and that edge is exactly what `cross-libc-dlopen.c` drops:

```
cross-libc-dlopen: rewritten load failed: .../libxml2.so.2.13.9: undefined symbol: fmod
cross-libc-dlopen: rewritten load failed: .../libstdc++.so.6.0.33: undefined symbol: fesetround
cross-libc-dlopen: rewritten load failed: .../libLLVM.so.20.1: libc.musl-x86_64.so.1: cannot open...
```

The last line is the cascade. `libLLVM` needed `libxml2` and `libstdc++`, which
had just failed, so `ld.so` fell back to loading the unrewritten originals,
which still carry the musl `DT_NEEDED`.

**Fix:** load every glibc library that can hold a re-homed name into the
**global** scope at startup: `libm.so.6`, `libresolv.so.2`, `libcrypt.so.1`,
plus glibc's own pre-2.34 split libraries. `cld_global_scope_libs[]` in
`src/cross-libc-dlopen.c`.

### 3.2 Bundled libraries were losing to host libraries

`cross-libc-dlopen.c` skips the dependency probe entirely for musl guests. That
part is correct: loading the host copy unstripped would drag musl libc into the
process. But the skip went straight to `cld_find_candidate()`, which only
searches directories on the active load stack. For a host object that is
`/usr/lib`, so **a bundled soname could never win**.

Measured on Alpine: the AppDir bundles `libstdc++.so.6.0.36` and
`libgcc_s.so.1`, and the host's `libstdc++.so.6.0.33` and `libgcc_s.so.1` were
loading alongside them. Two libstdc++ and two unwinders in one process is the
classic "every symbol resolves and nothing works" configuration.

**Fix:** check `$APPDIR/lib/<soname>` **before** hunting the host, for musl
guests too. Loading the bundled copy is always safe, because it is a glibc
object built against the runtime already running. After the fix:

```
T4.2 -- provenance of collision-surface sonames
    libstdc++.so.6     /w/AppDir/lib/libstdc++.so.6      BUNDLED (correct)
    libgcc_s.so.1      /w/AppDir/lib/libgcc_s.so.1       BUNDLED (correct)
    libxcb.so.1        /w/AppDir/lib/libxcb.so.1         BUNDLED (correct)
```

### 3.3 `dlerror()` was being consumed

The fallback path reads `dlerror()` unconditionally and only prints it under
debug. `dlerror()` is destructive, so with debug off, which is the default, the
caller's own `dlerror()` returns `NULL`:

```
FAILED: dlopen: (null)
```

The comment above that code says it "surfaces the classic error message users
know how to read". It does the opposite.

**Fix:** read `dlerror()` only when tracing is on, so the message survives for
the caller in the normal case.

### 3.4 Everything was being rewritten, whether or not it needed to be

`cld_scan_providers()` built its idea of "versions we can satisfy" from
`dlsym("malloc")` -> `dladdr` -> parse that one file. So it only ever learned
**libc's** version names. Every `GLIBCXX_*`, `CXXABI_*` and `LLVM_*` requirement
in a Mesa closure was therefore unvouchable, `cld_requirements_satisfied()`
returned 0 for all of them, and objects that needed nothing were rewritten
anyway. Reported independently in issue #1, from a Gentoo host whose glibc is
*older* than the bundled one, where the debug line says it outright:

```
cross-libc-dlopen: our libc provides 46 known versions
```

A `DT_VERNEED` record names a **file** and the versions wanted **from it**, so
that is the question to ask: resolve the file (bundled copy first, then whatever
is already loaded under that soname) and look in *its* `DT_VERDEF`.

The check also had to move. It ran before the dependency closure was walked, and
half the files a `DT_VERNEED` names are the object's own dependencies, none of
them loaded yet -- so the precise version of the question would have answered
"absent" for every one and stripped everything regardless.

Measured on `debian:trixie-slim`, host glibc 2.41 under a bundled 2.44:

| | objects rewritten | `/tmp` copies | result |
|---|---|---|---|
| as shipped | 6 | 6 | `enumerate -> -1` |
| after 3.4 | **0** | **0** | 1 device, llvmpipe |

Zero is the right answer there, and it also silences the Vulkan loader's
"path to given binary differs from OS loaded path" warning, because there is no
longer a rewritten copy for it to notice. On Alpine 5 objects are still
rewritten, which is unavoidable: they are musl-built. **E39** pins the count,
because a fix that merely stopped mattering would pass every other case.

### 3.5 The failure report accused the wrong thing

When a `DT_NEEDED` cannot be opened, every symbol it would have provided looks
unresolved. The report listed them and ended with:

```
Most likely the bundled glibc predates them. CROSS_LIBC_DLOPEN_RUNTIME=host
runs against the host's own libc, which will have them.
```

under 258 LLVM entry points. No libc has ever exported any of them, and
`CROSS_LIBC_DLOPEN_RUNTIME=host` cannot help. Found in issue #1 on a host that keeps
LLVM in `/usr/lib/llvm/22/lib64`, reachable only through `/etc/ld.so.cache`,
which a bundled `ld.so` patched to a private cache path does not read.

**Fix:** record which dependencies could not be opened and name them; offer the
glibc guess only when at least one unresolved symbol is shaped like something a
libc could own -- not `_Z`-mangled, not `LLVM*`. **E28**.

### 3.6 The failure report was itself destructive

Found while testing 3.5, and the same class of bug as 3.3 reached from the other
side. `cld_report_unresolved()` probes with `dlsym`, and **every probe that
misses replaces the pending `dlerror()` message**. The caller, about to ask for
it, was handed

```
/work/cross-libc-dlopen.so: undefined symbol: _ZN4llvm9Attribute16getWithAlignmentEv
```

-- this object blamed for a failure in a different one -- instead of ld.so's
actual `libvendor.so.1: cannot open shared object file`. The code carries a
comment saying it makes no `dlerror()` call, which was true and not enough.

**Fix:** re-run the load after the report, which puts the real message back.
One extra failed `dlopen`, only in a trace run. **E29**.

---

## 4. Design R: host-runtime selection

`src/runtime-select.c`. The forward-compatible half. If the host glibc is newer
and the set is complete, re-exec under the **host's** runtime, so a symbol
invented after the AppImage shipped resolves because the process is using the
future libc itself.

### 4.1 Two things the obvious implementation gets wrong

**A flat `--library-path "$HOST_LIBDIR:$APPDIR/lib"` breaks the bundling
guarantee.** It hands the host `libstdc++`, `libX11` and every other soname the
win too, in the same way section 3.2 did. Instead a **symlink farm** under
`$XDG_RUNTIME_DIR` holds the runtime set and nothing else:

```
--library-path  $FARM : $APPDIR/lib : $HOST_LIBDIRS
                ^^^^^   ^^^^^^^^^^^   ^^^^^^^^^^^^^
                libc    everything    fallback for
                only    bundled       what we lack
```

Symlinks, so no host file is touched and every write lands under
`XDG_RUNTIME_DIR`.

**A `DT_VERNEED` completeness check cannot detect a mixed runtime set.** This is
the more important correction. The obvious check, whether each member's
`DT_VERNEED` falls inside what its peers define, catches the direction where a
*new* object needs a version an *old* peer lacks. It provably cannot catch the
reverse, because **glibc never retires a version name**: an old `libdl.so.2`
asks libc only for `GLIBC_2.2.5`, and every later glibc still defines it.
Version names alone declare the mixed set healthy. It segfaults.

What discriminates is the `GLIBC_PRIVATE` symbol surface, which is not stable
at all. Measured, glibc 2.31 to 2.41:

```
old libdl.so.2       imports _dl_sym, _dl_addr, _dl_catch_error, _dl_vsym,
                     __libc_dlopen_mode        -> 2.41 exports NONE of them
old libpthread.so.0  13 imports absent from 2.41, incl. __libc_pthread_init,
                     _dl_make_stack_executable
old librt.so.1       9 absent, incl. __pthread_barrier_init, __shm_directory
```

So the implemented check is a **symbol** check. Every strong undefined symbol of
every member must be defined by the libc and `ld.so` it will be paired with.
Weak imports (`_ITM_registerTMCloneTable`, `__gmon_start__`) are skipped: they
are absent from every libc ever built and resolve to 0 by design, so counting
them would make every set look mixed.

The static check is then **verified empirically** before being committed to.
`runtime-select` forks and re-execs itself under the candidate runtime,
exercising malloc, TLS, stdio and `dlopen`, which is where a mixed set actually
dies.

Two traps in that self-test, both measured:

- It must re-exec **this binary**, not `/bin/true`. Rocky 9's `/bin/true` is a
  51-byte shell script, and `ld.so` answers `file too short`, which looks
  exactly like a mixed set and is not. Re-execing our own binary is also the
  stronger question, since it was linked against the bundled glibc.
- `/proc/self/exe` is the wrong way to find ourselves. Inside an AppImage this
  program starts as `$APPDIR/lib/ld-linux... runtime-select`, and when a loader
  is invoked explicitly the kernel exec'd the **loader**, so `/proc/self/exe`
  names `ld-linux`. Re-execing that asks one dynamic linker to run another as a
  program; it exits 127, indistinguishable from a broken runtime. Every newer
  host reported a false `SELF-TEST FAILED` until this was fixed.

### 4.2 Measured decision on all eight distros

Run against a fake AppDir bundling glibc 2.31, so the newer hosts really are
newer. The real AppImage bundles 2.44 and picks `bundled` everywhere, which is
correct, and is why the probe is run both ways.

| Host | Host glibc | Decision | Reason logged |
|---|---|---|---|
| debian bullseye | 2.31 | **bundled** | not newer than bundled |
| ubuntu 20.04 | 2.31 | **bundled** | not newer than bundled |
| rocky 9 | 2.35 | **host** | newer, set internally consistent |
| debian trixie | 2.41 | **host** | newer, set internally consistent |
| fedora 44 | 2.43 | **host** | newer, set internally consistent |
| opensuse tumbleweed | 2.43 | **host** | newer, set internally consistent |
| arch | 2.44 | **host** | newer, set internally consistent |
| alpine 3.22 | musl | **bundled** | no host glibc, bundled plus shim is the only option |

Every `host` decision also passed the empirical self-test. `host` on every
newer glibc, `bundled` on older, equal and musl, never a mixed set, always with
a logged reason.

**E20 and E21 are the guard and its control.** A deliberately mixed set (2.41
`ld.so` and `libc`, 2.31 `libdl`, `libpthread`, `librt`, `libutil`, every member
present so "incomplete" cannot be the reason) is **refused**, while the same
glibc unmixed is **accepted**. Without the control, a selector that refused
everything would pass.

### 4.3 The trade

Switching to the host runtime **gives up the bundle-everything guarantee**. The
app then runs against an unaudited host libc. That is a real cost and it is the
user's call, which is why `CROSS_LIBC_DLOPEN_RUNTIME=host|bundled|auto` exists and why
the decision and its reason are logged under `CROSS_LIBC_DLOPEN_DEBUG=1`.

---

## 5. Design B: the generated shim

`tools/gen_forward_shim.py`. The **selection** is generated; the
**implementations** come from an audited table. A generator that invented
semantics would be worse than the treadmill it replaces, not better. Solo splits
it the same way.

### 5.1 The floor, and what it means for this AppImage

The shipped `src/forward-shim.c` targets the demo AppImage's own bundled
runtime, **glibc 2.44**.

That is the headline finding of the ground-truth phase. The demo AppImage
bundles the newest released glibc, so **no distro in the matrix is newer**, the
selector correctly picks `bundled` on all of them, and the version gap is empty:

```
floor  : appdir-bundled glibc 2.44 (4287 symbols)
target : glibc-2.44             (4288 symbols)
musl   : 46 symbols musl exports and the floor does not
gap    : 47 symbols the floor lacks
   implementable    13
   stub-only        22
   irrelevant       12
```

The single non-musl gap symbol is `__libanl_version_placeholder`, an empty ABI
placeholder. **Case 1 is already solved for this artifact by bundling a
new-enough glibc.** It is not solved in general: any AppImage built on an older
distro has the gap, and this one acquires it the day glibc 2.45 ships.

So the generator is demonstrated at a realistic older floor as well. Floor 2.31,
target 2.44:

```
gap    : 628 symbols the floor lacks
   implementable   107
   stub-only       296
   irrelevant      225
```

Compiled with `-Wall -Wextra -Werror` on real glibc 2.31, with **42 documented
behaviours checked** (`tests/shim-selftest.c`, case E16), not just "it links":

```
  ok   strlcpy trunc          ok   stat matches __xstat     ok   bit_ceil(0)==1
  ok   strlcat trunc          ok   arc4random_uniform covers range
  ok   clz(0)==32             ok   _dl_find_object==-1      ok   sigabbrev_np(SIGKILL)
  ... 42 checks ...
SHIM TEST PASSED (0 failures)
```

### 5.2 What happens when an uncovered symbol appears

It fails loudly, naming the symbol, at the earliest point it can.

**At load time**, the dry-run and report path enumerates every strong undefined
symbol that neither the process nor the object's own dependency closure can
supply, and prints all of them, not just `ld.so`'s first.

**At call time**, a stub-only symbol aborts with its own name:

```
[cross-libc-dlopen] FATAL: sinpi: not implementable over this glibc
[cross-libc-dlopen] the bundled glibc 2.44 does not provide this symbol
[cross-libc-dlopen] and no implementation exists for it. Set CROSS_LIBC_DLOPEN_RUNTIME=host
[cross-libc-dlopen] to run against the host's own libc, which will have it.
```

**Why emit stubs at all.** Every Mesa object is `DF_BIND_NOW`, so `ld.so`
resolves the whole symbol table at load. One undefined symbol makes the library
unloadable even if that code path is never taken. A stub converts "cannot load
at all" into "works unless it genuinely needs this".

**Why C23 maths is stub-only, deliberately.** `sinpi`, `fmaximum_num`,
`roundeven` and the other 186 have exacting NaN, signed-zero and rounding-mode
semantics. An approximation that is subtly wrong is worse than a loud abort, and
no GPU driver calls them. This is a recorded decision, not an oversight: the
manifest carries a per-symbol reason for all 47.

### 5.3 The musl-only surface is larger than the Mesa closure suggested

`tools/gap.py` measures the union over the Mesa and LLVM closure as exactly
`['___environ', 'atexit']`, and that reproduces. But over the **whole** Alpine
`/usr/lib`, one more musl-only symbol is load-bearing:

```
cross-libc-dlopen: rewritten load failed: .../libX11.so.6.4.0: undefined symbol: issetugid
```

`issetugid` alone was blocking `libX11.so.6` and `libdbus-1.so.3`. It is
implementable exactly as musl implements it, over `getauxval(AT_SECURE)`.

The generator now takes `--musl <inventory>` and folds musl's 46 floor-absent
exports into the same enumerable gap, rather than relying on a hand-maintained
list. That is what took the corpus from 243/247 to **247/247**.

### 5.4 The `___environ` rename

Applied, and confirmed firing on the real `libLLVM.so.20.1`:

```
cross-libc-dlopen: ___environ -> __environ (st_name +1, no .dynstr write)
```

musl spells the environ pointer with three underscores, glibc with two. The
reference is a **weak** import, so it does not stop the load: it silently
resolves to 0 and the driver reads a NULL environment. Latent, and exactly the
class of bug that works until it does not.

The fix costs no string edits. `"___environ" + 1` **is** `"__environ"`, so
advancing `st_name` by one byte renames the reference. Two properties make this
total rather than merely likely, and both are checked:

- the symbol is **undefined**, so `DT_GNU_HASH`, which indexes only *defined*
  symbols from `symoffset` onward, does not cover it. No hash fixup.
- nothing is written to `.dynstr`, so tail-merging cannot bite. Tail-merging is
  real: 16 of 647 names in `libvulkan_lvp.so` are suffixes of another.

The general case, renaming to something that is not a suffix, needs an in-place
`.dynstr` write. `cld_dynstr_range_occupied()` refuses unless it can prove that
no other referenced offset (symbol name, `DT_NEEDED`, `SONAME`, `RPATH`,
`RUNPATH`, or a version-table name) falls inside the clobbered range. T0.7 tests
that it does refuse.

---

## 6. Goal 2: what works, and how the last blocker fell

### 6.1 What works

```
###### T2.2 cross-libc load the real host ICD ######
-- OFF --
FAILED: dlopen: libc.musl-x86_64.so.1: cannot open shared object file
-- ON --
  handle          : 0x55557a900a70
  vk_icdGetInstanceProcAddr: 0x7f8ded0d5d80
  vkCreateInstance          : 0x7f8ded0d44f0
OK: host ICD loaded and callable

###### T2.4 corpus, zero-regression gate ######
  before: TOTAL=247 OK=2
  after : TOTAL=247 OK=247
  regressions: 0

###### T2.3 debug trace ######
  times libvulkan_lvp.so rewritten: 1     (rewritten once, then cached)
  attempts to load a musl libc: 0
```

T2.4 is the result that separates a fix from a demo. Every one of the 247 musl
libraries in Alpine's `/usr/lib` loads into the glibc process, up from 2, with
zero regressions. Through the bundled Vulkan loader, `vkCreateInstance` against
the host ICD returns `VK_SUCCESS`.

### 6.2 T3.2, solved: an unversioned reference does not get the default definition

This was the open failure:

```
[Vulkan Loader] ERROR: setup_loader_term_phys_devs: Call to
  'vkEnumeratePhysicalDevices' in ICD /tmp/xdg/.cross-libc-dlopen-dbdb70ee.so
  failed with error code VK_ERROR_OUT_OF_HOST_MEMORY
vkEnumeratePhysicalDevices reported zero accessible devices.
```

It was attributed to glibc-vs-musl ABI differences. **It is not that**, and the
first measurement that mattered was reproducing it with no musl in sight.

#### The reproduction that broke it open

`debian:trixie-slim`, one libc, glibc 2.41 throughout. Debian's own
`libvulkan_lvp.so` is a glibc object. The only change from the working case is
that cross-libc-dlopen intercepts the load, and the only reason it intercepts is
that the ICD manifest was given an absolute `library_path` (Debian ships a bare
soname, which cross-libc-dlopen deliberately never touches, which is why nobody had
seen this on Debian):

```
=== feature OFF ===  deviceName = llvmpipe (LLVM 19.1.7, 256 bits)
=== feature ON  ===  WARNING: [lvp_device.c:1315] Code 0 : VK_ERROR_OUT_OF_HOST_MEMORY
                     ERROR: setup_loader_term_phys_devs ... VK_ERROR_OUT_OF_HOST_MEMORY
```

Same libc on both sides. So the ABI hypothesis is dead, and the mechanism is
the rewriting itself.

#### The chain, one measurement per link

Debian ships Mesa's `__FILE__` strings, so the failure names its own line.

| Link | How | Result |
|---|---|---|
| which Mesa call fails | the message itself | `lvp_device.c:1315` = `lvp_init_wsi()` |
| which WSI backend | gdb `FinishBreakpoint` on each `wsi_*_init_wsi` | `wsi_display_init_wsi` -> `VK_ERROR_OUT_OF_HOST_MEMORY`; x11 and wayland both `VK_SUCCESS` |
| which line inside it | gdb, stepping by line, both runs side by side | diverges at `wsi_common_display.c:2323`, `u_cnd_monotonic_init()` returns `thrd_error` where the working run returns 0 |
| which libc call | breakpoints on the three calls that inlines to | `pthread_condattr_init` 0, `pthread_condattr_setclock` 0, **`pthread_cond_init` 22 = `EINVAL`** |
| *which* `pthread_cond_init` | `info symbol $pc` at the breakpoint | failing run enters libc+`0x909f0`, working run libc+`0x91b00` |

```
$ nm -D /lib/x86_64-linux-gnu/libc.so.6 | grep -w pthread_cond_init
00000000000909f0 T pthread_cond_init@GLIBC_2.2.5     <- the failing run lands here
0000000000091b00 T pthread_cond_init@@GLIBC_2.3.2    <- the working run lands here
```

`pthread_cond_init@GLIBC_2.2.5` is `__pthread_cond_init_2_0`, kept for binaries
from before the 2003 condition-variable ABI change. Its entire body is
`if (cond_attr != NULL) return EINVAL;`. Mesa always passes an attribute,
because a monotonic clock is the only reason to build one.

#### Stated as a property of libc alone

E22 and E22b, no Vulkan, no musl, no AppImage -- one small object, built once,
then version-stripped exactly the way a host driver is:

```
  E22    versions stripped   probe_cond_init() = 22
  E22b   versions intact     probe_cond_init() = 0
```

**An unversioned reference does not get the default definition of a symbol.**
A stripped object has only unversioned references. So does every musl-built
object, which never had version information to begin with -- which is why the
same failure appeared on Alpine and on Gentoo with a glibc driver, and why it
looked like an ABI problem for as long as it did.

#### The fix

[`src/version-compat.c`](../src/version-compat.c) defines the trapped names itself.
The preload is ahead of libc in the global lookup scope, so every unversioned
reference in the process lands there, and each definition forwards to the
default one.

Finding "the default one" is the part that needed care. `dlsym` is not an
answer: measured in **E27**, `dlsym(RTLD_NEXT, "pthread_cond_init")` returns the
**obsolete** definition on glibc 2.31 and the default one on 2.41. So the
version name is read out of the defining object's own `.gnu.version_d` -- the
entry whose versym lacks the hidden bit -- and handed to `dlvsym`, which is
correct on both. No version string is hardcoded anywhere.

Which names to cover is not a judgement call either.
[`tools/version_traps.py`](../tools/version_traps.py) computes the set from a libc:
a name defined at two or more versions whose `st_value` **differs**. Same
address at several versions is re-versioning, not an ABI change -- the glibc 2.34
libpthread merge does that to 191 symbols and none of them can matter.

```
glibc 2.42  multi-version, same address (harmless): 191    different address (traps): 38
glibc 2.41  multi-version, same address (harmless): 191    different address (traps): 33
glibc 2.31  multi-version, same address (harmless):  10    different address (traps): 21
```

`make traps` fails the build if a libc has a trap `version-compat.c` neither
forwards nor explicitly declines, so a future glibc cannot introduce one
silently (**E26**).

That is not a hypothetical. Run against glibc **2.42** (Arch, Fedora 44) rather
than the 2.31 and 2.41 this was developed on, the audit failed with five
uncovered names:

```
cfgetispeed  cfgetospeed  cfsetispeed  cfsetospeed  cfsetspeed
                                       default=GLIBC_2.42  others=GLIBC_2.2.5
```

glibc 2.42 added arbitrary terminal baud rates, so the `GLIBC_2.2.5`
definitions speak the old `Bnnn`-encoded `speed_t` and the new ones take a real
number of bits per second. Nothing in a graphics driver closure calls them,
which is the point: the set grew under a glibc newer than any this was tested
on, and an audit that enumerates rather than reasons is what noticed. Now
covered; audited clean on glibc 2.31, 2.41, 2.42 (Arch) and 2.42 (Fedora 44). Three are declined on purpose, with reasons: `memcpy`
(both definitions satisfy the memcpy contract, checked byte-for-byte over 4096
size and alignment combinations in **E25**; interposing every memcpy in a
rendering process to fix nothing is not a trade worth making) and
`sys_nerr`/`_sys_nerr` (data objects, which a forwarder cannot alias, and from
glibc 2.32 neither has a default version at all, so an unversioned reference
fails loudly instead of quietly).

#### End to end

`alpine:3.22`, musl host, the demo AppImage bundling glibc 2.44, forced onto
Alpine's own musl-built lavapipe:

| | as shipped | feature off | **this repo, feature on** |
|---|---|---|---|
| `vkprobe` | segfault | `VK_ERROR_INCOMPATIBLE_DRIVER` | **1 device, llvmpipe** |
| host `/usr/lib` loadable | -- | 2 / 177 | **177 / 177** |
| libc families mapped | -- | -- | **one** |
| `vkcube` | `reported zero accessible devices` | -- | **`Selected GPU 0: llvmpipe (LLVM 20.1.8)`** |
| 100 load/unload cycles | -- | -- | **rss +68 kB, fds +0, copies +0** |
| 60 s continuous render | -- | -- | **rss/fds/threads flat at 6 s, 33 s, 60 s** |

The `feature off` column is why the rest of the table means anything: the same
command with the same binaries cannot use the host driver at all.

And the same thing with nothing forced at all -- **E40**, one file replaced
inside the AppDir, no `CROSS_LIBC_DLOPEN_*`, no `VK_DRIVER_FILES`, the marker the AppDir
already carries turning the feature on by itself:

```
as shipped   Do you have a compatible Vulkan installable client driver (ICD) installed?
with this    Selected GPU 0: llvmpipe (LLVM 20.1.8, 256 bits)
```

#### What this also fixed

The same defect ran the other way on a **glibc** host. Reported independently by
@QaidVoid on Gentoo
with a real `radv`, and reproduced here on `debian:trixie-slim`, whose glibc
2.41 is **older** than the bundled 2.44 -- so by construction nothing can be
missing and nothing needs rewriting:

| | vkcube |
|---|---|
| as shipped, feature on | `vkEnumeratePhysicalDevices reported zero accessible devices` |
| feature off | renders |
| this repo, feature on | renders |

Turning the feature on used to destroy a working configuration. See 3.4 for the
second half of that, which is that it should not have been rewriting anything
there in the first place.

#### One claim retracted

While reviewing this I asserted, in the issue thread, that lavapipe "has no
libdrm on the path at all". That is false and is corrected there. Alpine's
`libvulkan_lvp.so` links `libdrm.so.2` directly and references 35 drm symbols.
What is true, and measured:

```
$ readelf -d /usr/lib/libvulkan_lvp.so | grep -c libdrm_amdgpu
0
LD_DEBUG=libs, filtered to `calling init:`   ->   /w/AppDir/lib/libdrm.so.2
```

`libdrm` is on the path and the **bundled** copy is the one loaded, which is 3.2
working rather than libdrm being absent. `libdrm_amdgpu` -- the one that reads
`amdgpu.ids` through `AMDGPU_ASIC_ID_TABLE_PATHS` -- genuinely is not involved,
because lavapipe never references it. The conclusion held; the reason given for
it did not.

#### `glxgears`, the OpenGL path

**This paragraph used to end "no loader shim can supply a file the distribution
does not ship", and that sentence was wrong.** It is kept here, corrected, rather
than quietly rewritten, because the way it was wrong is the most transferable
thing in this report.

What was measured, and is still true: Alpine's `mesa-gl` is classic Mesa, not
libglvnd, so there is no `libGLX_<vendor>.so.0` for the AppImage's bundled
libglvnd to `dlopen`. That is host packaging, not libc.

What was asserted and never tested: that this made it unfixable. A shim cannot
supply the missing *file*, but it can replace the object that was looking for
it. `glxgears` now renders on Alpine's classic Mesa, and so does everything else
`glprobe` exercises. Section 9 is the whole chain.

---

## 7. The closed-source driver, the ABI, and real silicon

Three things this report carried as UNVERIFIED for its whole life are measured
here: a **proprietary** host driver, the **cross-libc ABI** microtests T1.3-T1.7,
and rendering on an actual **GPU**. Cases E41-E53 in
[`experiments/40-appimage.sh`](../experiments/40-appimage.sh); the suite reports
them on both hosts and SKIPS them by name where the capability is absent.

The headline is not the one the task predicted, so it goes first.

### 7.1 A proprietary driver is the least likely library to need this fix

The target is NVIDIA's WSL CUDA userspace, reachable through `/dev/dxg`. It is
the one class of host library nothing else here covers: a vendor binary that
cannot be inspected, cannot be rebuilt, and was linked against a libc nobody in
this project chose.

It loads, and it works:

```
E41   handle          : 0x55557363f2d0
      provenance      : /usr/lib/wsl/lib/libcuda.so.1
      cuInit          : ok
      driver version  : 13.0
      devices         : 1
      device[0]       : NVIDIA GeForce RTX 3050 Ti Laptop GPU
      device memory   : 4095 MiB
      OK: 1 CUDA device(s), 4096 bytes round-tripped through the GPU and verified
```

The round trip is deliberate. A handle proves only that `ld.so` was satisfied;
`cuMemcpyHtoD` and `cuMemcpyDtoH` with a byte-for-byte compare exercise ioctls
on the device node, the vendor's own threading and its allocator, under a libc
runtime the vendor never saw, and none of them fails.

**And every control passes too.** E41b runs the identical command with
`CROSS_LIBC_DLOPEN=0`; E41c runs it with **no preload in the process
at all**, so neither this repository's shim nor upstream's nor the version-trap
forwarders are present; E43a runs the shipped one. All four get the same result.
That is not a defect in the test, it is the answer:

```
$ objdump -T /usr/lib/wsl/lib/libcuda.so.1 | grep -o 'GLIBC_[0-9.]*' | sort -uV
GLIBC_2.2.5
```

A vendor ships against the oldest floor it can, precisely so its blob runs on
everything. Nothing in it can be missing from a bundled glibc 2.44, so the shim
has nothing to do, and E42 measures that directly: **0 objects rewritten, 3
examined and left unchanged** -- the E39 rule arriving from a real vendor binary
instead of a synthetic probe. The claim E41/E41b support is therefore the
*regression* claim: turning the feature on does not break a driver that already
worked.

E46 puts the vendor's own binary on the end of it. `nvidia-smi` is NVIDIA's, not
ours; it `dlopen`s `libnvidia-ml.so.1` itself, and under the AppImage's bundled
glibc on **Alpine** it reports the GPU. E46a is its control, and on a musl host
it is unambiguous: the same binary run without the AppImage's runtime does not
execute at all. The precise reason is worth stating, because the obvious phrasing
is wrong -- musl's `ld.so` is never asked. The binary's `PT_INTERP` names
`/lib64/ld-linux-x86-64.so.2`, Alpine has no such file, and the kernel fails the
`execve` with ENOENT before any loader runs. E46a requires that message NOT to be
a shared-library one, so the case cannot pass on E44's failure by mistake.

```
E46    GPU 0: NVIDIA GeForce RTX 3050 Ti Laptop GPU (UUID: GPU-df849629-...)
E46a   env: can't execute '/usr/lib/wsl/lib/nvidia-smi': No such file or directory
```

### 7.2 What the vendor stack did need: two condvar ABIs in one process

Section 6.2 established the version-binding trap from libc alone. The CUDA stack
is the first place it has been caught in **shipping third-party software**, and
it is caught by reading the answer out of the running process rather than
inferring it. [`tests/bindprobe.c`](../tests/bindprobe.c) walks each loaded object's
relocations, reads the address the loader put in the slot, and names the file and
symbol version behind it. `LD_DEBUG=bindings` cannot do this: it prints the
version a reference *asked for*, and for this trap the whole point is that the
reference asks for nothing.

Microsoft's `libdxcore.so`, which `libcuda.so.1` loads to reach `/dev/dxg`,
carries no symbol versioning at all:

```
$ readelf -V /usr/lib/wsl/lib/libdxcore.so | grep -c 'Version needs'
0
$ readelf -V /usr/lib/wsl/lib/libd3d12.so  | grep -c 'Version needs'
0
$ readelf -V /usr/lib/wsl/lib/libcuda.so.1 | grep -c 'Version needs'
1
```

So it imports every libc symbol unversioned -- structurally identical to a
musl-built object, and to an object this project's own rewriter has stripped.
`libd3d12.so` is the same shape and is in the *graphics* stack rather than this
one (section 7.5); it is shown here only because two independent vendor blobs
being built this way is the point.

[`tools/manual/trap_users.py`](../tools/manual/trap_users.py) intersects an object's imports with
the traps of the libc it will resolve against:

```
$ python3 tools/manual/trap_users.py $APPDIR/lib/libc.so.6 /usr/lib/wsl/lib/libdxcore.so
libc .../libc.so.6: 38 trap(s), 191 benign re-versioning(s)

== libdxcore.so
   imports              : 140
   trapped names among them: 6
   symbol versioning    : ABSENT, so every one of those references is unversioned
                          and binds the OBSOLETE definition
     memcpy                     default=GLIBC_2.14   obsolete=GLIBC_2.2.5
     pthread_cond_broadcast     default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_destroy       default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_signal        default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_timedwait     default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_wait          default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
```

NVIDIA's own `libnvidia-ml.so.1` names ten trapped symbols and is versioned, so
every one of them binds correctly. Which object is at risk is decided by how it
was linked, not by who wrote it.

The consequence, measured with the AppImage exactly as it ships (E43a):

```
  pthread_cond_wait
      libdxcore.so                 -> libc.so.6 @GLIBC_2.2.5
      libcuda.so.1.1               -> libc.so.6 @GLIBC_2.3.2
      VERDICT: MIXED (2 implementations)

  BINDINGS MIXED: 6 symbol(s) measured, 5 MIXED
```

One process, one driver stack, two different implementations of five condition
variable entry points -- and the two differ in how they read the first eight
bytes of a `pthread_cond_t`, which is the 2003 ABI change section 6.2 is about.
With this repository's preload the same measurement is (E43):

```
      libdxcore.so                 -> cross-libc-dlopen.so+0x6c80
      libcuda.so.1.1               -> cross-libc-dlopen.so+0x6c80
      VERDICT: uniform

  BINDINGS UNIFORM: 6 symbol(s) measured, 0 MIXED
```

**What this does not claim.** The mixed binding is latent, not currently fatal:
`cuInit` returns 0 and the GPU round trip succeeds in both states. Whether a
`pthread_cond_t` ever crosses the `libdxcore`/`libcuda` boundary is not visible
from outside two closed-source blobs. If one ever does, the two sides read it
two different ways. The fix removes the question rather than answering it.

### 7.3 One blind spot, three sightings

The `/etc/ld.so.cache` item has been an open design question since the first
pass. It now has a symptom, from a real driver, three times over.

WSL makes its GPU userspace reachable by writing a file:

```
$ cat //wsl$/podman-machine-default/etc/ld.so.conf.d/ld.wsl.conf   # a real WSL distro
# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [automount]
# ldconfig = false
/usr/lib/wsl/lib
```

Nothing else names that directory. Anylinux patches `ld-linux.so` to skip the
cache (E13b), so `--library-path` is the only discovery mechanism left, and
whatever assembles it decides what exists.

**Sighting one, compute (E44).** `libcuda.so.1` opens by absolute path and loads
fine. Inside `cuInit` it `dlopen`s `libdxcore.so` by **bare soname**, which
`cross-libc-dlopen` deliberately never intercepts, so it reaches `ld.so` and is not
found. The error the user sees is not "cannot open shared object file":

```
FAILED: cuInit -> 100          # CUDA_ERROR_NO_DEVICE
```

E45 appends the directories `/etc/ld.so.conf` names and the same command
completes the GPU round trip. The conf file is plain text, so reading it gets the
benefit of the cache without touching the binary cache whose parsing is why the
cache was inhibited.

**Sighting two, Design R.** `runtime-select` assembles its own
`--library-path` from a hardcoded `rs_host_libdirs[]`, which has the same blind
spot. This one was found by reading the list rather than by a failure, so it was
measured afterwards, building the file from the commit before the change and
after it against the same driver:

```
=== runtime-select, before the conf-dirs change ===
   directories on the path: 8
   /usr/lib/wsl/lib present: NO
   FAILED: cuInit -> 304 CUDA_ERROR_OPERATING_SYSTEM
=== runtime-select, after the conf-dirs change ===
   directories on the path: 10
   /usr/lib/wsl/lib present: yes
   OK: 1 CUDA device(s), 4096 bytes round-tripped through the GPU and verified
```

A **third** distinct symptom for one cause, and again not a missing library: 304
rather than E44's 100, because the process is running the host's glibc 2.41
rather than the bundled 2.44 and `libcuda` gives up at a different point. The fix
is `rs_conf_dirs()`, which reads `/etc/ld.so.conf`, follows its `include` globs
with recursion bounded by both depth and a total file budget, sorts each
directory's entries so the path is reproducible, and appends what it finds
**after** the hardcoded list, so bundled and host-runtime directories keep their
existing precedence. E52 is the after-state as a standing case; the before-state
above is a one-off, because keeping it would mean shipping a switch that exists
only to turn a bug back on.

**Sighting three, graphics (E53a).** The strongest one, because the symptom
implicates the wrong subsystem entirely. Mesa's `d3d12_dri.so` `dlopen`s
`libd3d12.so` by bare soname; sharun assembles the path; sharun's host-GPU
directory list is hardcoded and contains `/run/opengl-driver/lib` and
`/run/current-system/sw/lib` but not `/usr/lib/wsl/lib`. What the user sees:

```
Error: glXCreateContext failed
```

That reads as a display or driver fault. It is a missing directory. `LD_DEBUG=libs`
is what settles it:

```
897:  find library=libd3d12.so [0]; searching
897:    trying file=/w/AppDir/lib/libd3d12.so
897:    trying file=/usr/lib/x86_64-linux-gnu/libd3d12.so
897:    trying file=/run/opengl-driver/lib/libd3d12.so
897:    trying file=/run/current-system/sw/lib/libd3d12.so
                                               ... and never /usr/lib/wsl/lib
```

E53 hands sharun the conf-derived directories through its own
`SHARUN_FALLBACK_LIBRARY_PATH` -- no file edited, nothing patched -- and the
AppImage renders on the GPU. All three sightings are one computation, and that
computation now lives **upstream**:
[pkgforge-dev/Anylinux-sharun@`54208d2`](https://github.com/pkgforge-dev/Anylinux-sharun/commit/54208d2bc7d4c919ba46a6c234f6af7f8426b537) adds the `/usr/local/*`
directories and appends the ones it scrapes out of `/etc/ld.so.cache`. The
patch this repository carried is deleted rather than kept in parallel. What that
change does not reach -- musl's `/etc/ld-musl-<arch>.path`, the multiarch
triplets past three, and the non-FHS prefixes -- is recorded in
[`ground-truth.md`](ground-truth.md) with the measurement
behind it, because a cache scrape can only name a directory that held a library
when `ldconfig` last ran.

### 7.4 The cross-libc ABI, measured

T1.3 through T1.7 were SKIPPED and UNVERIFIED for the whole project. They are
written now: [`tests/abi-guest.c`](../tests/abi-guest.c) is one source file built
twice, by glibc on the floor and by musl on Alpine, and
[`tests/abi-host.c`](../tests/abi-host.c) drives the crossings. The size table both
sides fill comes from one inline function in
[`tests/abi-abi.h`](../tests/abi-abi.h) compiled into both, so the two columns can
differ only because the headers do.

The musl build is loaded **through `cross-libc-dlopen` itself**, which is what drops
its libc edge -- no `patchelf`, no stand-in. E48 is the control that fails:

```
E48   FAILED: dlopen: libc.musl-x86_64.so.1: cannot open shared object file
E49   ABI CROSSING PASSED: 26 checks, 0 failed
E47   ABI CROSSING PASSED: 27 checks, 0 failed        (same-libc control)
```

Every crossing holds. Memory allocated in the musl object is freed by the
process and the reverse; an `errno` set inside it is read outside it in the same
thread; a `FILE*` opened by the process is written from inside it and read back;
a mutex made on either side is locked from the other; and a condition variable
the process waits on is signalled from inside it. Both sides reach one `malloc`,
one `free`, one `__errno_location`, one `pthread_mutex_lock` and one `stdout`
FILE object.

**The size divergences are real and mostly harmless, and the report can finally
say which.** A size table alone cannot tell those apart, so the probe measures
offsets too:

```
    regmatch_t             guest=16       host=8        <-- DIVERGES
    struct rusage          guest=272      host=144      <-- DIVERGES
    struct sched_param     guest=48       host=4        <-- DIVERGES
    ucontext_t             guest=936      host=968      <-- DIVERGES
    FTW_D                  guest=2        host=1        <-- DIVERGES   (all seven)
    O_LARGEFILE            guest=32768    host=0        <-- DIVERGES
    sizeof regoff_t        guest=8        host=4        <-- DIVERGES
    off rusage.ru_maxrss   guest=32       host=32
    off rusage.ru_nivcsw   guest=136      host=136
    off stat.st_mode       guest=24       host=24
    off stat.st_size       guest=48       host=48
    off dirent.d_name      guest=19       host=19
    off sched.priority     guest=0        host=0
```

Every field the probe measures is at the same offset in both. `struct rusage`
differs by 128 bytes of trailing reserved space and `struct sched_param` by 44;
neither moves a field anybody reads.

Which leaves the direction that does break, and it is not the one the hazard list
implied. Handing the guest storage the host allocated is safe, because the guest
calls **glibc's** implementation, which writes glibc's layout into glibc-sized
memory: all four guard bands survive (T1.7b). The hazard is one step further on,
where the guest reads a glibc-filled struct back at its **own** offsets:

```
  T1.7c -- the guest reading back a struct glibc filled
    DIFF regexec, read back at own stride     host=7 guest=12884901888
         LIVE HAZARD: regoff_t is 4 bytes here and 8 there
    same getrusage, read back at own offset   host=6084 guest=6084
    DIFF nftw, dirs counted with own FTW_D    host=2 guest=0
         LIVE HAZARD: FTW_D is 1 here and 2 there
```

Nothing crashes. `regexec` reports a match ending at byte 7 and the musl-built
caller reads 12884901888 out of the same array; `nftw` walks a tree with two
directories in it and the musl-built caller counts none.

Six hazards were listed. They do not all end in the same place, and the
difference between measured and argued is worth keeping:

| Hazard | Verdict | On what basis |
|---|---|---|
| `regmatch_t` / `regoff_t` stride | **LIVE** | measured: host reads 7, guest reads 12884901888 from the same array |
| the seven `FTW_*` values | **LIVE** | measured: host counts 2 directories, guest counts 0 |
| `struct rusage` | benign | measured: sizes differ by 128 bytes of trailing reserve, `ru_maxrss` and `ru_nivcsw` are at the same offsets, and the guest reads the same value the host does |
| `struct sched_param` | benign | measured: `sched_priority` is at offset 0 in both, and the guard band around a host-allocated one survives the guest filling it |
| `ucontext_t` | **argued, not measured** | 936 vs 968 bytes, and nothing here calls `getcontext`/`swapcontext` across the boundary, so no crossing exists to measure. It would matter to a guest that made or swapped a context the process also touched |
| `O_LARGEFILE` | **argued, not measured** | 0 on glibc x86-64, `0100000` on musl. A guest passing musl's value to glibc's `open` sets the kernel flag glibc considers implied on 64-bit, which is a no-op there; that is a reading of the two headers, not a test |

E50 asserts the count of LIVE rows, so it fails if a future libc moves one.

No loader shim can fix the live two: an offset compiled into an object is not
something a preload can reach. They are a property of loading musl-built code
into a glibc process, and the honest statement is now four measured verdicts and
two arguments rather than a worry about six.

### 7.5 Hardware, at last, and the caveat that was wrong twice

"No GPU" was the standing caveat of this whole project. It was wrong the first
time (there are two GPUs, and the NVIDIA one is live from Linux) and wrong again
in its correction (`/dev/dri` is absent, so radv/anv/radeonsi are out -- but they
are not the only way to reach a GPU).

Mesa's **d3d12 Gallium driver** does not need a DRM render node. It talks to
`/dev/dxg` through Microsoft's `libdxcore`, and Debian packages it:
`/usr/lib/x86_64-linux-gnu/dri/d3d12_dri.so`. That makes the host's own OpenGL
driver a hardware driver, and the AppImage's bundled libglvnd finally has a real
vendor library to drive.

Rung 1 of the diagnostic ladder first, natively, with no AppImage involved:

```
$ GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
  xvfb-run -a -s '-screen 0 1024x768x24 +extension GLX +render' glxgears -info
GL_RENDERER   = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)
GL_VERSION    = 4.6 (Compatibility Profile) Mesa 25.0.7-2+deb13u1
GL_VENDOR     = Microsoft Corporation
579 frames in 5.0 seconds = 115.707 FPS
```

Then through the AppImage, which is 7.3's third sighting and its resolution:

```
E53a  Error: glXCreateContext failed                                (as it stands)
E53   GL_RENDERER   = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)  (+ conf dirs)
      606 frames in 5.0 seconds = 120.965 FPS
      507 frames in 5.0 seconds = 101.138 FPS      (the next interval)
```

**No file is modified and nothing is patched, but four environment variables
are set**: `SHARUN_FALLBACK_LIBRARY_PATH` with the directories `/etc/ld.so.conf`
names, and `GALLIUM_DRIVER`, `MESA_D3D12_DEFAULT_ADAPTER_NAME` and
`LIBGL_ALWAYS_SOFTWARE=0` to choose the hardware driver and which of the two
GPUs it drives. E40 remains the case that forces nothing; this one is not that
case and does not claim to be. The first of those four is the only one this
project is responsible for, and it is the one the sharun patch removes the need
for.

**E53b does not flip.** With the feature off the same command still renders, and
saying otherwise would be claiming a control that did not happen. The host GL
stack here is glibc-built against glibc 2.41, older than the bundled 2.44, so
there is nothing for the shim to do -- the same reason as E41b and E42. What E53
measures is that the path works on hardware, not that the shim made it work.

Vulkan stays on lavapipe. Mesa's Vulkan-on-D3D12 driver (`dzn`) is not packaged
by Debian, and building it is the one remaining route to a hardware-backed
**Vulkan** ICD.

### 7.6 Design R, with a device on the end

Design R selected correctly on eight distros and passed its self-test, and had
never had a driver on the end of the choice. E51 and E52 put one there. Read the
first three rows together: they run the **same** host Vulkan ICD and differ only
in how the process got a libc that can satisfy it.

| Case | Runtime | Feature | Driver | Result |
|---|---|---|---|---|
| E31 | bundled | off | host lavapipe | no devices |
| E32 | bundled | on | host lavapipe | 1 device (the shim half) |
| E51 | **host** | none at all | host lavapipe | 1 device (the Design R half) |
| E52 | **host** | none at all | NVIDIA `libcuda.so.1` | the round trip, on the RTX 3050 Ti |

The switch is forced with `CROSS_LIBC_DLOPEN_RUNTIME=host`. Auto declines on this host
and is right to: the bundled glibc 2.44 is newer than the host's 2.41, so a
switch could only lose, and that is the rule E17 measures. What E51 and E52
measure is whether the switched runtime can drive a real device, not whether it
should have been chosen.

The two halves of the design are now each demonstrated end to end, on the same
host, against the same driver, and they remain independent: on a musl host only
the shim half exists, which is why the musl row of the matrix has no escape
hatch (risk 4).

---

## 8. Test results

Tests are grouped by what they need to run. Tier 0 is static analysis on any
OS. Tier 1 is the evidence table. Tier 2 needs a real driver but no GPU. Tier 3
is end to end. Tier 4 checks invariants. Tier 5 needs hardware.

### Tier 0, static

| ID | Test | Result |
|---|---|---|
| T0.1 | musl gap is exactly two symbols | **PASS.** `['___environ', 'atexit']` |
| T0.2 | binding-mode audit | **PASS.** Every closure member `BIND_NOW` |
| T0.3 | TLS audit | **PASS.** No `DF_STATIC_TLS`, every `PT_TLS memsz` under 4 KiB (max 56 bytes) |
| T0.4 | rewriter round-trip | **PASS.** All four version tags gone together, size unchanged, re-parses |
| T0.5 | idempotence | **PASS.** Second strip byte-identical, content-hash name stable |
| T0.6 | `atexit` interposition safety | **PASS.** `nm -D` shows exactly one exported definition, checked by the Makefile |
| T0.7 | tail-merge guard | **PASS.** Refuses a range containing another live reference, allows a clear one |
| T0.8 | malformed-input fuzz | **PASS.** Every truncation and bit flip refused or bounded |

T0.4, T0.5, T0.7 and T0.8 run against the **real implementation**:
`tests/elf-selftest.c` includes `cross-libc-dlopen.c` rather than modelling it,
because a Tier-0 test that models the C can pass while the shipped code is
wrong.

### Tier 1, the evidence table

`sh scripts/run-evidence.sh` reports **53/53 predictions held on x86-64** and
**50/50 on aarch64**, both measured in CI on the same commit, run
[32952579071](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32952579071).
`experiments/run.ps1` drives the same three stage scripts for a machine with
PowerShell and no POSIX shell.

⚠ **The two totals differ by exactly the three cases aarch64 SKIPS**, each
naming the capability it lacks rather than the difference being unexplained:

| case | why it skips on aarch64 |
|---|---|
| E22 | that libc exports `pthread_cond_init` at one symbol version. The trap needs an obsolete definition beside the current one |
| E23 | skipped WITH E22 deliberately. With no trap present the stripped object already returns 0, so E23 would pass whether or not `version-compat.c` does anything |
| E58 | section M's trampoline is hand-written x86-64 machine code. What the real aarch64 trampolines do is measured by E69 through E73 and E76/E76b, natively on the ARM runner |

⭐ **E23's skip is the one worth reading.** It was reporting MATCH on the ARM
runner while asserting nothing, and skipping it with E22 is what stopped that.
53 minus 3 is 50, and no case is missing for a reason nobody wrote down.

E1 through E13 measure the problem. E14 through E21 are one per fix from the first pass: the
ELF self-test, the generated-shim compile and behaviour, and five selector
decisions including the mixed-set guard and its control. E22 through E29 are
the version-binding trap and the reporting defects; E54 through E58 and E69
through E76b are the loader mechanisms section 9 rests on, each stated in
objects small enough that the mechanism is the only thing being measured:

| ID | What it pins |
|---|---|
| E22 | the bug, stated in libc alone: version-stripped object, `pthread_cond_init` returns `EINVAL` |
| E22b | its control: the same object unstripped returns 0, so the probe and the container are exonerated |
| E23 | the fix: the same stripped object with the preload merely present returns 0 |
| E24 | the obsolete definition really does reject the attribute Mesa passes |
| E25 | the `memcpy` exclusion is justified: 4096 size/alignment combinations, byte-identical |
| E27 | which resolution primitive may be trusted; `dlsym(RTLD_NEXT)` is not one |
| E26 | the audit: no glibc may add a trap `version-compat.c` neither forwards nor declines |
| E28 | the report names the dependency that failed to open, instead of accusing the libc |
| E29 | and the caller still gets ld.so's message, not one of the report's own `dlsym` misses |
| E54 | a plugin's undeclared import cannot see its loader's closure when that closure was loaded `RTLD_LOCAL` |
| E55 | its control: `RTLD_GLOBAL`, same two files, and it resolves |
| E56 | preload constructors run in REVERSE of the `.preload` order |
| E57 | its control: swap the two and the first line swaps, so it is the order and not the file |
| E58 | a tail-jump trampoline forwards eight integer registers, nine float registers, a varargs call and a struct return without knowing any of their signatures |
| E69 | the same four shapes through the register-saving RESOLVER, and the second call agrees with the first |
| E70 | the target was chosen at the CALL and not in a constructor |
| E71 / E71b | the same binary, one argument apart: links the soname and calls nothing, the target is not mapped; calls once, it is |
| E72 | an entry point the target does not provide, CALLED: a line naming it, and zero returned |
| E73 | the distinct-name call count an application can be measured by |
| E75 / E75b | the shim finds a target in a directory only `/etc/ld.so.conf` names, and does not when the conf file is removed |
| E76 / E76b | the aarch64 trampolines and resolver RUN, under qemu-user, forwarding and absent paths both |

E69 through E76b are built from the **real** `src/gl-fwd.c` with a five-name
table rather than from a copy of the resolver, because a copy is a thing that
drifts from what ships.

### Tier 1b, the AppImage end-to-end suite

`experiments/appimage.ps1` runs real AppImages against real host drivers on
five stages:

| stage | what it is | result |
|---|---|---|
| `alpine:3.22` | musl, classic Mesa -- the case the complaint is about | **40/40**, 5 named skips |
| `debian:trixie-slim` | glibc, glvnd -- the regression case | **45/45**, no skips |
| `ubuntu:14.04` | glibc 2.19, classic Mesa 10.1, no Vulkan | **26/26**, 19 named skips |
| `ubuntu:16.04` | glibc 2.23, classic Mesa 18.0.5, no Vulkan | **26/26**, 19 named skips |
| gtk4-demo on `alpine:3.22` | not a host -- a different APPIMAGE, self-contained, a real GTK4 application | **7/7**, no skips |

The first four run the same 45 cases, so matched plus skipped is 45 on each and
the skip count is the count of what that host cannot be asked. It fetches the
demo AppImage once (sha256 verified), extracts it in a container because the
payload is DwarFS, builds `src/` on the glibc 2.31 floor, builds the musl half
of the ABI probe on Alpine, and then measures E30 through E79 on each host;
the fifth stage fetches a second AppImage and measures E80 through E83.
Every case is run with the feature off and on, and against both the shipped
`cross-libc-dlopen.so` and the one built from `src/`, because a one-sided result
cannot tell a working fix from a fallback that was already happening.

The five skips on Alpine are named rather than counted: no host glibc runtime
set to switch to (E51, E52), and no Vulkan-or-GL-on-D3D12 driver (E53a, E53,
E53b). The nineteen on each Ubuntu host are **fourteen** that need a Vulkan
device -- Mesa 10.1 predates Vulkan entirely -- plus E53a/E53/E53b for the same
reason as Alpine, plus E59/E60, whose tools need python 3.6 and which measure
the BUNDLE rather than the host, so the other stages establish them. The
fourteenth is **E67**, a Vulkan case that lives in the OpenGL section because
what it measures is that the GL shims cost the Vulkan path nothing; it was
guarded where the section is rather than where the case is, and on the first
pre-glvnd run it reported MISMATCH for a capability the host does not have. On a
machine with no GPU at all the driver's own capability probe turns E41-E53 into
skips as well, and the suite still passes -- that is the point of probing rather
than assuming.

**E38 is retired rather than renumbered.** It was `glxgears`, run on a host with
a libglvnd vendor library and SKIPPED on one without, and its skip reason
carried a verdict -- "no loader shim can supply a file the distribution does not
ship" -- that was never tested and was wrong. E61 and E62 replace it by
measuring BOTH host classes instead of declining to look at one of them. Section
9.1 is why that distinction is worth a paragraph.

### Tier 2, 3 and 4

| ID | Test | Result |
|---|---|---|
| T2.1 | Alpine native lavapipe baseline | **PASS**, named by `vulkaninfo` |
| T2.2 | cross-libc load the real ICD | **PASS** |
| T2.3 | rewritten once, cached, no musl libc load | **PASS** |
| T2.4 | corpus, zero regressions | **PASS.** 2/247 to 247/247, 0 regressions. Re-measured by E33/E34 on a leaner Alpine image: 2/177 to 177/177. The denominator is however many `.so` files the image happens to have; the ratio is the result |
| T2.5 | selector across the distro matrix | **PASS** |
| T2.6 | forced `CROSS_LIBC_DLOPEN_RUNTIME=bundled` on a newer host | **PASS** (E19) |
| T2.7 | cache-only library found via `--library-path` | **PASS** (E13c) |
| T3.1 | Alpine baseline fails before the fix | **PASS with a caveat**, below |
| T3.2 | `vkcube` with the host driver | **PASS.** `Selected GPU 0: llvmpipe (LLVM 20.1.8)` on Alpine, feature on; `reported zero accessible devices` as shipped. Section 6.2 |
| T3.3 | `glxgears` | **PASS on all three host classes** (9.11 added pre-glvnd glibc). On a glvnd host it always worked and still does (E61, E62). On Alpine's classic Mesa it failed with `couldn't get an RGB, Double-buffered visual` and now renders (E61, E62), through `gl-fwd.so`. Section 9 |
| T3.5 | EGL on a host with no glvnd EGL vendor | **PASS where the host's own EGL can do it.** `eglprobe` goes from `EGL_NO_DISPLAY` to a working surfaceless context on Alpine and on Ubuntu 14.04 (E65, E66). On Ubuntu 16.04 it does not -- and it does not NATIVELY either, with no AppImage in the process (E79), so the shim is reproducing the host rather than failing. 9.11 |
| T3.6 | every bundled loader classified | **PASS for the demo AppDir.** 8 objects import `dlopen`, 0 unclassified (E59). ⚠ Not a property of AppImages in general: the gtk4 AppDir has 9 UNCLASSIFIED, named in 9.10 and not yet looked at |
| T3.4 | driver provenance is the host's | **PASS**, below |
| T3.7 | GL past the `glxgears` symbol set, with the frame read back | **PASS.** `glprobe` returns `64 128 191 255` from the pixel it cleared, on all three host classes (E63, E64, and 9.11). ⚠ Numbered T3.7 because it was added as a second T3.4 and collided with the row above, which is the one the "T3.4 detail" paragraph explains |
| T4.1 | exactly one libc family | **PASS.** glibc mapped, musl not, with the feature on (E35) |
| T4.2 | bundled wins, via `dladdr` | **PASS** |
| T4.3 | no host file modified | **PASS.** Identical sha256 over `/usr/lib`, `/lib`, `/etc/ld.so.conf.d` |
| T4.4 | no regression on glibc hosts | **PASS**, below, and E30-E39 on `debian:trixie-slim` |
| T4.5 | 100 load/unload cycles, and 60 s of continuous rendering | **PASS.** Cycles: rss +68 kB, fds +0, rewritten images +0 over 99 steady-state cycles (E36). 60 s: rss 157656 kB, 5 fds, 48 threads, identical at t=6 s, 33 s and 60 s |

**T3.1 caveat.** Its condition is "fails with a *symbol-resolution* error, not a
display error". At the AppImage level, under `xvfb-run -a`, the message is
`vkEnumeratePhysicalDevices reported zero accessible devices`, a device error,
because the Vulkan loader swallows an ICD that fails to load and reports only
the absence. The symbol-resolution error is real but one layer down, visible
directly at T2.2 and in the trace:

```
FAILED: dlopen: libc.musl-x86_64.so.1: cannot open shared object file
```

The baseline does fail for the right reason, but the criterion as written is
only satisfied by looking below the loader. Counting it as a clean pass on the
AppImage message alone would be wrong.

**T3.4 detail.** The mapped driver is
`$XDG_RUNTIME_DIR/.cross-libc-dlopen-dbdb70ee.so`, not a path under `$APPDIR`, so the
bundled-software-rendering trap is avoided. That file is the rewritten copy of
the host's driver, which the Vulkan loader itself confirms:

```
[Vulkan Loader] DEBUG | DRIVER: Searching for ICD drivers named /usr/lib/libvulkan_lvp.so
[Vulkan Loader] WARNING | LAYER: Path to given binary /usr/lib/libvulkan_lvp.so
                was found to differ from OS loaded path /tmp/xdg/.cross-libc-dlopen-dbdb70ee.so
```

The indirection is inherent: the whole mechanism is loading a *rewritten* copy,
so provenance has to be established through the rewrite, not by the mapped path.

**T4.4 detail.** The AppImage run on three glibc hosts with the **stock
upstream** preload and with the patched one, in both modes. The outcome is
identical in all twelve combinations, which is what "unchanged" means:

```
### Arch Linux (glibc 2.44)      ### Ubuntu 20.04 LTS      ### Debian trixie (2.41)
    stock    mode=0  rc=1            stock    mode=0  rc=1     stock    mode=0  rc=1
    stock    mode=1  rc=1            stock    mode=1  rc=1     stock    mode=1  rc=1
    patched  mode=0  rc=1            patched  mode=0  rc=1     patched  mode=0  rc=1
    patched  mode=1  rc=1            patched  mode=1  rc=1     patched  mode=1  rc=1
```

`rc=1` everywhere because these containers have no GPU, no display and no Vulkan
driver installed. The AppImage fails the same way before and after. The point of
the test is the equality, not the exit code.

### Every test that was once skipped, and where it stands now

Five of these -- T1.3 through T1.7 -- were SKIPPED and UNVERIFIED for the life of
this project and are resolved here rather than quietly dropped. The other four
each still carry something unverified, and each says what would unblock it.

```
T1.3  PASS - allocator ownership crosses in both directions. Memory
      malloc'd inside a musl-built guest is freed by the process and the
      reverse; strdup likewise. Both sides reach one malloc and one free,
      named by dladdr. E49, section 7.4.

T1.4  PASS - one errno location. A failing open inside the musl guest sets
      ENOENT and the process reads 2 from its own errno in the same thread,
      before anything else can clobber it. E49.

T1.5  PASS - a FILE* opened by the process is written from inside the musl
      guest and read back byte for byte, and both sides carry the same
      stdout FILE object address. glibc's FILE is 216 bytes and musl's is
      neither, so only one of them can be right about the object; the
      measurement says which. E49.

T1.6  PASS - a mutex made by the process is locked and unlocked from the
      guest and left unlocked; a mutex the guest allocated with its own
      sizeof is locked by the process; and a condition variable the process
      waits on is signalled from the guest, bounded by a 5 s timeout so a
      broken binding fails rather than hangs. E49. Not run under TSan: that
      remains UNVERIFIED.

T1.7  PASS, with two live hazards named. The divergences are real --
      regmatch_t 16 vs 8, rusage 272 vs 144, sched_param 48 vs 4,
      ucontext_t 936 vs 968, all seven FTW_* off by one, O_LARGEFILE
      32768 vs 0 -- and mostly harmless, because every named FIELD is at the
      same offset in both. What is NOT harmless is a musl-built object
      reading back a struct glibc filled at its own stride: regexec reports
      a match ending at byte 7 and the guest reads 12884901888, and an nftw
      walk over two directories counts none. Those two cannot be fixed from
      a loader shim. E50 fails if the count of live hazards ever changes.
      Section 7.4.

T3.3  PASSES on all three host classes, and this entry used to say the opposite.
      Alpine's mesa-gl is classic Mesa, so no libGLX_<vendor>.so.0 exists for
      the AppImage's bundled libglvnd to dlopen -- that part was measured and
      is still true. The conclusion drawn from it, that no loader shim could
      close the gap, was never tested and was wrong: src/gl-fwd.c replaces the
      dispatcher instead of supplying its missing vendor, and glxgears renders
      on Alpine (E61, E62), as does everything glprobe exercises past the 33
      symbols glxgears imports (E63, E64). Still PASSES on a glibc host with
      libglvnd, in software and on hardware (E53, GL_RENDERER = D3D12 (NVIDIA
      GeForce RTX 3050 Ti Laptop GPU)). Section 9.

T5.1  PARTIAL - no DRM render node, which is NOT the same as no GPU, which
      in turn is not the same as no hardware result. This machine has a
      discrete NVIDIA GeForce RTX 3050 Ti Laptop (driver 580.97) and an
      Intel Iris Xe, both live from Linux, and neither reachable through
      /dev/dri: WSL2 publishes no DRM render nodes at all, so radv, anv and
      radeonsi cannot initialise however much silicon is present.

      What does reach them is /dev/dxg. Mesa's d3d12 GALLIUM driver needs no
      DRM node and Debian packages it, so the OpenGL path runs on hardware
      (E53, GL_RENDERER = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU), 121
      FPS through the unmodified AppImage). NVIDIA's CUDA userspace reaches
      the same device for compute (E41, E52).

      Still UNVERIFIED: hardware VULKAN. Mesa's Vulkan-on-D3D12 driver
      (dzn) is microsoft-experimental and Debian does not package it, so
      every ICD result here is lavapipe. Hardware-specific failures in the
      DRM drivers -- libdrm ioctl ABI above all -- stay UNVERIFIED and need
      a non-WSL Linux host.

T5.2  PASS, and the result is not the one the task predicted. NVIDIA's
      libcuda.so.1 is a real closed-source glibc-built host driver, and it
      loads under the AppImage's bundled glibc 2.44 on Alpine and
      round-trips 4096 bytes through the GPU (E41). So does the control with
      the feature off, and upstream's shim, and no shim at all: the blob is
      built against a GLIBC_2.2.5 floor, so nothing in it can be missing and
      zero objects are rewritten (E42). A proprietary driver turns out to be
      the LEAST likely host library to need this fix.

      What the vendor stack did need is in section 7.2: Microsoft's
      libdxcore.so and libd3d12.so carry no symbol versioning at all, so as
      shipped the CUDA stack binds two different pthread_cond_* families in
      one process (E43a, 5 of 6 symbols MIXED). This repository's preload
      makes them one (E43). Latent rather than currently fatal; the limit of
      that claim is stated where it is made.

      Still UNVERIFIED: the proprietary GRAPHICS driver. /usr/lib/wsl/lib
      has no libGLX_nvidia.so.0, no nvidia_icd.json and no /dev/nvidia*, so
      the closed-source GL and Vulkan drivers cannot be tested here at all.

T5.3  SKIPPED - no aarch64 hardware. This machine is x86_64 (i7-12700H).
      The code is arch-parameterised (RS_LDSO, RS_TRIPLET, the syscall
      number fallbacks) but this is UNVERIFIED outside x86-64.
```

---

## 9. The second boundary: a bundled dispatcher whose plugin the host lacks

Everything in sections 3 through 8 is about **one** kind of gap. The bundled
Vulkan loader `dlopen`s the host's ICD; the ICD was built against another libc;
`cross-libc-dlopen.so` carries it across. The host had the driver all along and the
only thing in the way was libc.

This section is about a gap of a different kind, which was in the README for a
whole session labelled "not fixable" and is now closed.

### 9.1 The skip that carried a verdict

None of this section would exist without
a pull request from @Samueru-sama, which arrived
from outside and pointed at a gap this repository had written off. The design
here differs from it in five ways, each measured below, but the gap and the
mechanism are its finding.

The previous report recorded case E38 like this:

```
E38  SKIPPED  no libGLX_<vendor>.so.0 on this host; its Mesa is not libglvnd,
              so the bundled libglvnd has no vendor to dlopen
```

and the README said, in the same breath:

> No loader shim can supply a file the distribution does not ship.

The **reason** was correct and measured. The **verdict** attached to it was
neither. A SKIP is a statement about the environment -- this host lacks that
capability -- and it is allowed to name the missing capability. It is not
allowed to decide whether the gap is closable, because that is a claim about the
design space and needs its own evidence. Welded together, the skip stopped being
a question, and one line of untested prose kept OpenGL broken on every musl
distro for the whole of the previous session.

That is the process defect worth carrying forward, and section 9.10 is the
mechanism that makes it harder to repeat.

### 9.2 Two gaps, not one

| | what is wrong | what fixes it |
|---|---|---|
| **G1, the libc gap** | the host has the plugin, it is nameable, and it was built against a libc the bundle is not | `cross-libc-dlopen.so`: rewrite the object so its version requirements stop mattering, drop the musl libc edge, bridge the imports |
| **G2, the interface gap** | the host has the *capability* but ships nothing in the shape the bundled loader looks for | replace the bundled loader |

Vulkan only ever exhibits G1, and that is a property of its design rather than
luck: the loader/ICD boundary is thin and universal, every ICD exposes
`vk_icdGetInstanceProcAddr`, and every distribution that has Vulkan ships one.

OpenGL exhibits G2. The AppImage bundles libglvnd, which is a **dispatcher**: an
application links `libGL.so.1`, and at first use `libGLX.so.0` behind it
`dlopen`s a vendor library, `libGLX_<vendor>.so.0`. (Which of those two objects
does the opening matters, and section 9.10 is about how easy it is to name the
wrong one.) A host whose Mesa was built without glvnd -- every musl distro, and
every pre-glvnd glibc distro such as Ubuntu 14.04 or Debian 8 -- ships no such
file at all. There is nothing for `cross-libc-dlopen` to carry. The user sees:

```
Error: couldn't get an RGB, Double-buffered visual
```

which is a message about visuals, for a fault that is about neither visuals nor
libc.

### 9.3 What a shim that replaces a library has to export

The repair is [`src/gl-fwd.c`](../src/gl-fwd.c): an object built with SONAME
`libGL.so.1` and preloaded, so ld.so binds the application's `DT_NEEDED` to it
and never loads the bundled dispatcher. At the first GL call it picks a target
and every entry point forwards there -- the **bundled** dispatcher when the
bundle or the host has a vendor library for it, where it works and the shim's
job is to be invisible, and the host's classic `libGL.so.1` otherwise.

The one correctness rule is that **it must export everything the object it
replaces exports**, because anything less is `undefined symbol` for the first
application that links a name outside the list. The bundled `libGL.so.1`
(libglvnd 1.7.0, from the `__FILE__` strings it keeps -- `../libglvnd-v1.7.0/src/...`
-- rather than from the `.so.1.7.0` suffix, which encodes the OpenGL ABI version
and would have said the same thing for the wrong reason) exports **3470**
functions.

A hand-written subset is not a smaller version of this design, it is a different
and worse one, and the difference is invisible from the outside. The 33-symbol
column below is not a strawman: it is the shim proposed by @Samueru-sama, which
identified the mechanism correctly and forwarded exactly the set `glxgears`
imports. Measured on Alpine 3.22, same AppDir, same `.preload`, two shims:

```
33 of 3470     GL_RENDERER : llvmpipe (LLVM 20.1.8, 256 bits)
               glprobe: symbol lookup error: undefined symbol: glGetIntegerv
3470 of 3470   GL_RENDERER : llvmpipe (LLVM 20.1.8, 256 bits)
               readback rgba: 64 128 191 255 (want ~64 128 191 255)
               OK: GL is complete
```

Both print a renderer. `glxgears` renders under both, because `glxgears` imports
exactly 33 GL symbols and a shim written to make `glxgears` run passes a
`glxgears`-shaped test. That is why [`tests/glprobe.c`](../tests/glprobe.c) exists
and why it **reads a pixel back**: a shim that exports a name but cannot forward
it returns zero, the frame comes out black, and no amount of grepping for
`GL_RENDERER` tells the two apart.

So the list is generated. [`tools/gen_gl_fwd.py`](../tools/gen_gl_fwd.py) reads the
export table out of the bundled `libGL.so.1` itself; `make gl-syms-check` fails
the build if the checked-in table and the bundled library disagree, and E60 runs
that check against the real extracted AppDir on every host with python 3.6+.
A newer bundled
libglvnd cannot add an entry point silently.

### 9.4 Trampolines, not wrappers -- and the slot that can run code

Each entry point is three instructions:

```asm
glClearColor:
	endbr64
	mov    $0xc1, %r11d            # 193, its own index
	jmp    *glfwd_tab+8*193(%rip)
```

The middle one is the whole of what changed since this section was first
written, and it is worth the paragraph. A table slot is an ADDRESS, so nothing
could happen AT a call: every entry point's fate had to be decided in a
constructor, before the application had asked for anything. That forced two
defects this file used to carry -- the host GL stack was loaded in every
process whether or not it would ever be used, and an entry point the host does
not implement was indistinguishable from one that worked and returned zero.

The index is the repair. It is known at ASSEMBLY time, so the trampoline puts
it in `%r11` -- the one register the SysV ABI lets a PLT destroy, which is
exactly what makes it free to carry a value across a call boundary -- and jumps
through the slot as before. A resolved slot ignores it. An unresolved slot
points at `glfwd_resolve_asm`, and there the index is the whole message.

`glfwd_resolve_asm` is `_dl_runtime_resolve` minus the bookkeeping: save `rax
rdi rsi rdx rcx r8 r9 r10 xmm0-7`, call `glfwd_resolve_one(index)`, restore,
tail-jump to whatever it returned. `and $-16,%rsp` after saving `%rbp` makes
the alignment unconditional rather than argued -- a trampoline is reached from
anywhere and the `movaps` faults on a misaligned address. On aarch64 the index
rides in `x17`, because `x16` was already the branch register and both are the
intra-procedure-call scratch registers that exist to be destroyed by veneers.

E69 measures it with the same four shapes E58 uses, and adds the one E58 cannot
ask: **the second call must agree with the first.** Single-sided, a resolver
that got lucky once and a resolver that wrote the right address into the slot
are indistinguishable.

```
E69  OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12]
     second-call-identical=yes absent-returned=0
```

Two tables, not one. `glfwd_tab` is the jump table and stays lazy per name;
`glfwd_addr` is what `dlsym` said, filled in ONE pass when the target loads.
The split is about `dlerror()`: `dlsym` leaves a message behind on every miss,
reading it to clear it is destructive, and doing the whole table in one pass
confines that theft to a single moment -- the first GL call in the process --
instead of scattering it through an application's lifetime. The shim says so
under `CROSS_LIBC_DLOPEN_DEBUG=1` when it actually took something.

not a C function with a hand-written prototype. This is not a micro-optimisation.
A tail jump preserves every argument register, the return value and the varargs
count in `%al`, so it forwards **any** signature correctly, including the ones
nobody typed out; a prototype that disagrees with the real one corrupts
arguments silently, and 3470 opportunities to get one wrong is not a risk worth
carrying for a shim whose whole purpose is transparency.

E58 pins the claim rather than asserting it, on the same trampoline shape the
generator emits:

```
E58  OK: ints=204 floats=285.00 varargs=10 struct=[2..12]
```

Eight integer registers, nine float registers, a varargs call whose `%al`
carries the float count, and a struct returned through hidden memory -- through
a jump that knows none of their shapes.

Three details that are load-bearing:

- **Every slot is initialised statically**, to the resolver rather than to
  NULL. A NULL slot is a crash inside a GL call with no explanation; a
  constructor-filled table has an ordering hazard (9.6) that a static
  initialiser does not; and an address decided before the application ran is
  the thing 9.4 above is about. An entry point the target cannot provide ends
  up at `glfwd_absent`, which returns zero in both return registers.
- **`endbr64` is spelled as bytes**, so the floor's assembler cannot be too old
  for it, and the shims are built `-fcf-protection=full`.

  ⚠ **CORRECTION, measured.** This entry previously said the flag makes the
  object carry the matching IBT property note. It does not, on any Debian floor
  tried. Built in `debian:bullseye-slim` and read back with `readelf -n`, the
  shipped `gl-fwd.so` has only `.note.gnu.build-id`; there is no
  `.note.gnu.property` section at all. A trivial one-function shared object
  compiled in the same image behaves identically, with the flag and without
  it. Repeated on `debian:bookworm-slim` (gcc 12.2) and `debian:trixie-slim`
  (gcc 14.2): no note in any of them.

  ```
  gcc -shared -fPIC -O2 -fcf-protection=full t.c -o a.so && readelf -n a.so
  ```

  ⛔ **SECOND CORRECTION, measured, and it reverses part of the first.** The
  paragraph above used to say the note is absent "with `-Wl,-z,ibt,-z,shstk`
  added" as well. **That clause was wrong on all three images.** With that
  linker flag the note IS emitted, every time. The full table, and the reason
  the note would be FALSE if it were forced, is in 9.13 below.

  The `endbr64` instructions ARE emitted; what is missing is the note that
  tells the loader the object is IBT-capable.
  `scripts/verify-artifacts.sh` reports the note's absence on every build, and
  refuses a build whose `endbr64` are missing, which is the part the flag
  actually delivers.
- **The shim refuses to forward to itself.** Its SONAME *is* the name it
  resolves, so anything that hands that name back -- ld.so matching a request
  against the shim's own libname list, an `CROSS_LIBC_DLOPEN_GL_HOST_DIR` pointing at the
  preload's own directory, a future loader that dedups by SONAME after load --
  would make every trampoline jump to itself. That is unbounded recursion inside
  the first GL call, with a stack overflow for a diagnostic. One `dladdr` on the
  first resolved pointer turns it into a sentence. E68 fires it deliberately:

```
 [gl-fwd.so] >> target /tmp/glfwd-self/libGL.so.1 -- host library (no vendor
                library for the bundled one)
 [gl-fwd.so] >> libGL.so.1: the target resolves back to this shim
                (/w/AppDir/lib/gl-fwd.so); refusing to forward to ourselves,
                all 3470 entry points return zero
FAILED: no RGB double-buffered visual
```

  The last line is the application's own documented failure, which is the right
  thing for it to see. A guard nobody has fired is a guard nobody knows the
  shape of.

### 9.5 `RTLD_GLOBAL`, asked for by the caller and not by everyone

A plugin does not always declare everything it uses. It can import a symbol with
**no** `DT_NEEDED` edge to whoever defines it and rely on its loader's closure
being in the global scope -- which, for `libGL`, is where it sits natively,
because the application has a `DT_NEEDED` on it. A loader that `dlopen`s `libGL`
`RTLD_LOCAL` breaks that without touching either file, and the plugin fails with
`undefined symbol` for a symbol that is present in the process.

The reported instance is classic Mesa's DRI driver importing `_glapi_*` with no
edge on `libglapi.so.0`. **That instance is not reproduced here**, and the last
paragraph of this section says what was found instead. The mechanism is what is
measured.

E54 and E55 reproduce the mechanism in three objects of two lines each rather
than by excavating a 2014 Mesa, because it is a property of `ld.so` and not of
Mesa:

```
E54  FAIL  ./libplug.so: undefined symbol: prov_symbol      middle object RTLD_LOCAL
E55  OK    plug_entry()=8                                   middle object RTLD_GLOBAL
```

Same two files, nothing else changed.

`gl-fwd` therefore passes `RTLD_GLOBAL` when **it** opens the host `libGL`, and
`cld_attempt` is unchanged. Making every cross-libc `dlopen` global would cover the
same case and would additionally put every host ICD's exports in the global
scope ahead of libraries loaded later -- a win over bundled definitions that
they do not have natively either, and a direct erosion of T4.2. The narrow
version reproduces the native shape exactly and nothing more.

And the instance, measured on the two Mesas available here:

```
alpine:3.22  Mesa 25.1  no libglapi.so.0 on the system at all; libGL defines no
                        _glapi_* and depends on libgallium-25.1.9.so instead
alpine:3.15  Mesa 21.2  libglapi.so.0 exists, swrast_dri.so imports 9 _glapi_*
                        symbols AND carries libglapi.so.0 in its DT_NEEDED
```

So neither needs the global scope for this. The report that a DRI driver still
relies on it is against Mesa 10.1, comes from outside this repository, and is
plausible -- the `DT_NEEDED` edge is a later addition -- but it is not
reproduced here and is not adopted as if it were. What justifies the flag is
E54/E55 plus the fact that `RTLD_GLOBAL` is what a `DT_NEEDED libGL` has
natively: the shim is reproducing a shape, not working around a bug.

### 9.6 Preload constructors run in reverse

⚠ **This section describes a hazard that gl-fwd no longer has, and it is kept
because the mechanism is real and the next shim will have it.** When `gl-fwd`
loaded its target in a CONSTRUCTOR, it needed the bundled libc runtime set that
`cross-libc-dlopen.so`'s constructor puts in the global scope -- a host object
whose musl libc edge was dropped cannot load without it -- and so the order of
two constructors mattered. It loads at the first GL call now (9.4), by which
time every preload constructor in the process has long since run, so the race
is gone for this object.

What is not gone is the loader behaviour, and the intuitive answer to it is
still wrong:

```
E56  --preload "A B"   ->  ctor-B first
E57  --preload "B A"   ->  ctor-A first
```

ld.so runs preload constructors in **reverse** of the list. Listing `gl-fwd.so`
after `cross-libc-dlopen.so` -- which is what a reader would write, and what the
obvious packaging note says -- runs it **first**.

E57 is not redundant with E56: without it, "reverse order" cannot be
distinguished from "B always happens to go first".

Rather than depend on an ordering nobody documents, `cross-libc-dlopen.so` exports
an idempotent `cross_libc_dlopen_init_now()` and `gl-fwd` calls it before its first
`dlopen`. That call is now belt-and-braces rather than load-bearing -- the
lazy load made the ordering moot -- and it stays for two reasons: it costs one
`dlsym` once, and it keeps the `.preload` order free for the NEXT preload that
does work in a constructor. E56 and E57 are what a packager should read before
writing an ordering note, and they are the reason `.preload` in this repository
has no required order.

### 9.7 End to end, on two host classes -- and see 9.11 for the third

The point of measuring both is that they fail in opposite directions. On a
classic-Mesa host the shim is the only thing that makes GL work; on a glvnd host
GL already worked and the shim's job is to change nothing.

⭐ Two was the whole story when this section was written and it is not now:
9.11 adds the pre-glvnd GLIBC hosts, which are classic like Alpine and glibc
like Debian, and 9.12 adds an AppImage of the other SHAPE. Read those two after
this one; the tables below are still exactly what they say, on the two hosts
they name.

**alpine:3.22, musl, classic Mesa 25.1, no glvnd vendor library:**

| | no shim | with the shim |
|---|---|---|
| `glxgears` | `Error: couldn't get an RGB, Double-buffered visual` (E61) | `GL_RENDERER = llvmpipe (LLVM 20.1.8)` (E62) |
| `glprobe` | `FAILED: no RGB double-buffered visual` (E63) | `OK: GL is complete`, readback `64 128 191 255` (E64) |
| `eglprobe` | `FAILED: eglGetDisplay -> EGL_NO_DISPLAY` (E65) | `OK: EGL is complete` (E66) |
| `vkcube` | -- | `Selected GPU 0: llvmpipe` (E67) |

**debian:trixie-slim, glibc 2.41, glvnd:**

| | no shim | with the shim |
|---|---|---|
| `glxgears` | `GL_RENDERER = llvmpipe (LLVM 19.1.7)` (E61) | unchanged (E62) |
| `glprobe` | `OK: GL is complete` (E63) | unchanged (E64) |
| `eglprobe` | `OK: EGL is complete` (E65) | unchanged (E66) |
| `vkcube` | -- | `Selected GPU 0: llvmpipe` (E67) |

E65 is worth reading twice. With **only** the GL shim loaded, EGL still fails on
the classic host: the two dispatchers have independent vendor-discovery
mechanisms -- a `libGLX_*.so.0` for GL, a JSON file under
`/usr/share/glvnd/egl_vendor.d` for EGL -- so they are genuinely two boundaries
and fixing one does not fix the other. `egl-fwd.so` is the same source file built
with a different table and a different vendor marker.

E67 is the regression case: the shims are preloaded for every binary in the
AppDir, `vkcube` included, and the Vulkan path is unaffected.

Totals with this section in: **40/40 on the musl host** with five named skips,
**45/45 on the glvnd glibc host** with none, **26/26** on each of ubuntu:14.04
and ubuntu:16.04 with nineteen named skips, **7/7** on the gtk4 stage, and
**53/53** in the container suite on x86-64, and **50/50** on aarch64 with the
three skips named in section 8.

### 9.8 What the shim does not do, stated as a number

On Alpine 3.22 the split is:

```
libGL.so.1: 2373 of 3470 entry points resolved from the host library
            (1357 exported, 1016 via glXGetProcAddressARB, 1097 absent)
```

`dlsym` alone finds 1357. Half of what glvnd exports are extension entry points
that classic Mesa implements without putting them in `.dynsym`, and the designed
way to reach those has always been `glXGetProcAddress`; asking it for the misses
adds 1016. The remaining **1097 are extensions this Mesa does not implement at
all** -- vendor extensions glvnd knows the names of and Mesa 25.1 has no code
for. They forward to the zero-returning stub.

That is the same answer an application would get natively on that host, where
those names are equally absent. But the number is a property of the host's Mesa,
not of this shim, so the shim reports the split under `CROSS_LIBC_DLOPEN_DEBUG=1`
rather than presenting 2373 as a score. On the glvnd host the same line reads
`3470 of 3470 ... (3470 exported, 0 via glXGetProcAddressARB, 0 absent)`, which
is what transparency looks like when it is measured instead of asserted.

**And calling one is now a line, not a zero.** This was the shim's own worst
failure mode -- 1097 silent no-ops by construction, in a repository that spends
more words warning about silent zeros than about anything else. The resolver in
9.4 is what made it reportable: an absent name keeps its slot pointing at the
resolver, so the FIRST call to it arrives somewhere that knows which name it is.

```
 [gl-fwd.so] >> ABSENT entry point called: glFooEXT -- this host's libGL.so.1
                has no implementation; returning zero
```

Not fatal. Returning zero is what the application gets natively on a host where
the name is equally absent, and making it fatal would be a policy decision about
somebody else's Mesa taken inside a shim.

⭐ **The question that could not be asked before: how many of the 1097 does a
real application actually touch?**

```
alpine:3.22, glprobe through the full AppDir
  libGL.so.1: 2373 of 3470 entry points resolved from the host library
  libGL.so.1: 15 of 3470 entry points were CALLED (15 forwarded, 0 absent)
              out of 2373 this host could resolve
  absent entry points this application reached: 0
```

**Zero.** The estimate this replaces was "likely zero, and likely is the
problem". The other number in that line is worth as much: `glprobe` touches
**15 of 3470**, which is 0.4% -- and a real GTK4 application (9.11) touches 46
GLES entry points and one GL one, because its renderer is GLES. "It replaces
libGL" has always rested on the export count; these are the first measurements
of use.

### 9.9 What it costs a process that never calls GL

Nothing beyond mapping the shim itself. That is a change: this section used to
record 30 ms and 30 MB of HOST MESA, and the gate that would have avoided them
as deliberately not written.

The shims are preloaded for every binary in an AppDir, so a Vulkan-only run
used to load the whole host GL stack and never touch it. The reason it was not
gated was that the gate under consideration -- "does anything in this process
have a `DT_NEEDED` on the soname I am impersonating" -- means walking every
loaded object's dynamic section, and `d_ptr` in a mapped `PT_DYNAMIC` may be
absolute or link-time depending on the port (7.3). Trading a measured 30 MB for
an unmeasured segfault class was not a trade worth making, and it still is not.

The resolver in 9.4 removes the need for it. Nothing resolves until something
calls, so the question "will this process use GL" never has to be answered in
advance -- it answers itself, at the first call, by there being one.

Measured both ways, because each answers half of it. On the clock and the
resident set, which is what the old figure was:

```
vkprobe on alpine:3.22, both shims in the preload, best wall of three
and max RSS of three:

  no shims                          0.28 s   230344 KB
  shims, default (lazy)             0.24 s   230988 KB
  shims, CROSS_LIBC_DLOPEN_GL_EAGER=1    0.36 s   259824 KB
```

The default costs **0.6 MB** over no shims at all -- the two shim objects being
mapped -- and no wall time this measurement can distinguish from noise; the
lazy row coming out 0.04 s FASTER than the no-shims row is what run-to-run
variation looks like at this scale, not an improvement. Eager costs **29 MB and
0.12 s** over lazy, which is the host Mesa closure being mapped and is the
figure this section used to record as the price of the default.

And on the process rather than on a clock, because "it started faster" is not
evidence about WHAT was loaded:

```
E71   OK: shim mapped=1 target mapped=0 (called=-1)      links the soname, no call
E71b  OK: shim mapped=1 target mapped=1 (called=204)     the same binary, one call
E74   Vulkan-only run: 2 shim(s) loaded, 0 resolved, no host GL mapped
E74b  the same shims, after a GL call: 2373 of 3470 entry points resolved
```

E71 alone would also pass if the shim were merely broken, which is why E71b is
the same binary one argument apart.

`CROSS_LIBC_DLOPEN_GL_EAGER=1` restores the old behaviour -- resolve everything
before `main()` -- so the cost of not doing it stays a measurement rather than a
memory, and so "how much of this dispatcher could this host stand behind" can
still be asked as a question about the host rather than about a particular run.
In that mode the exit summary says the forwarded call count is NOT measured,
rather than printing a smaller number under the same words.

The packaging answer is still better for a bundle with no GL application in it:
do not list the shims in `.preload`. That is a decision the person building the
AppDir can make correctly and the shim cannot.

### 9.10 The generalisation, and the tool that makes it a measurement

The OpenGL gap survived a session because finding it required somebody to
*wonder* whether libglvnd was a loader. That should not depend on wondering: a
bundled object that imports `dlopen` is a loader by construction, and the set of
them is a property of the bundle that can be read off it.

[`tools/plugin_boundaries.py`](../tools/plugin_boundaries.py) does exactly that, and
E59 runs it against the extracted AppDir with `--check`, which fails on any
loader that is not classified. The demo AppDir has eight:

```
covered     libvulkan.so.1      ICD from /usr/share/vulkan/icd.d      (E30-E37)
covered     libGLX.so.0         glvnd's vendor dlopen                 (E61-E64)
covered     libEGL.so.1         glvnd EGL -> egl_vendor.d             (E65, E66)
unmeasured  libX11.so.6         loadable i18n modules, on a build with them
n/a         libGLdispatch.so.0  glvnd internal dispatch, no host plugin
n/a         libdecor-0.so.0     libdecor-rs: decorations linked in
n/a         vkcube, vkmark      dlopen the BUNDLED libvulkan/libX11/libxcb
```

Two of those rows are the argument for the tool.

**`libGL.so.1` is not on the list, and that is the correct answer.** The object
that actually `dlopen`s the vendor library is `libGLX.so.0`; glvnd's
`libGL.so.1` is a re-export layer over it and imports no `dlopen` at all. A
human enumerating "which bundled libraries load host plugins" writes down
`libGL.so.1`, because that is the name in the failure. The tool writes down the
object that does the loading.

**`libdecor-0.so.0` is on the list because the tool found it**, not because
anyone thought of it. It turned out to be benign -- `libdecor-rs`, with the
decoration plugins linked in, so its only `dlopen` is a lazy one for the bundled
`libwayland-client.so.0` -- but "benign, checked" and "never looked at" are
different states and only one of them was true before.

⭐ **And the argument for the tool got its strongest instance after this
section was written.** The gtk4 AppDir from 9.12 is 272 libraries rather than
91, and thirty seconds of the same command says:

```
covered 2   n/a 1   unmeasured 3   UNCLASSIFIED 9
```

Two of the three `unmeasured` are `libgbm.so.1` and `libva.so.2` -- boundaries
this report names below as having no AppImage here to measure them on. There is
one now. And one of the nine UNCLASSIFIED is **`libepoxy.so.0`**, which is
itself a GL entry-point loader: it `dlopen`s `libGL`, `libEGL` and `libGLESv2`
by soname and resolves through them. That is the same DISPATCHER shape as
libglvnd, in the path of the application section 9.12 uses, and it is very
likely why gtk4-demo's counts come out 1 GL and 46 GLES. Nobody has looked at
it. It is recorded in CONTINUE 4.2 rather than investigated here, and it is
recorded because the tool found it rather than because anyone wondered.

The third verdict, **`unmeasured`**, exists for the same reason and is
deliberately not folded into either of the others. `libX11.so.6` can load i18n
modules from `/usr/lib/X11/locale` when it is built with them; nothing here has
run that. Calling it `covered` because it is "just another host object" is the
exact move that produced the OpenGL gap, and a state with no word for it becomes
invisible again.

The table also carries the boundaries this AppDir does **not** have, so that an
AppImage which bundles them is classified on sight rather than investigated from
scratch: `libva.so.2` (`<name>_drv_video.so` from `/usr/lib/dri`),
`libvdpau.so.1`, `libasound.so.2` (ALSA plugins), `libOpenCL.so.1`
(`/etc/OpenCL/vendors`), `libgbm.so.1`. Each is the same shape as the OpenGL one
and none of them is a libc problem. They are named, not fixed.

### 9.11 The third host class: pre-glvnd GLIBC

Sections 9.1 to 9.10 measure two host classes, and the sentence they support --
"every musl distro, and every pre-glvnd glibc distro" -- had evidence for one
of them. Ubuntu 14.04 and 16.04 are the other: glibc, classic Mesa, no
`libGLX_<vendor>.so.0` anywhere.

| host | libc | Mesa | `glxgears` | `glprobe` | `eglprobe` |
|---|---|---|---|---|---|
| alpine:3.22 | musl | 25.1.9 | llvmpipe (LLVM 20.1.8) | OK | OK |
| ubuntu:14.04 | glibc 2.19 | 10.1.3 | Gallium 0.4 on llvmpipe (LLVM 3.4) | OK | OK |
| ubuntu:16.04 | glibc 2.23 | 18.0.5 | llvmpipe (LLVM 6.0) | OK | fails, and see below |
| debian:trixie | glibc 2.41 | 25.0.7 (glvnd) | unchanged | unchanged | unchanged |

Mesa versions read off the package or `libgallium-<version>.so`, not off the
renderer string: `llvmpipe (LLVM 20.1.8)` names LLVM, and 25.1.8 is not a Mesa
version that exists. This table said it for one revision.

**The resolution counts match an independent run on hardware nobody here has.**
@Samueru-sama reported
Ubuntu 14.04 from a seven-distro matrix on an RX 580:

```
reported : 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
measured : 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
```

Different hardware, different display path, different Mesa point release, same
numbers. A generated table that reproduces to the entry point across eight Mesa
versions is the strongest thing said about it anywhere in this report.

**Two findings came out of 16.04 and neither is about the shim.**

The first is the `/etc/ld.so.cache` blindness for the fourth time. The host
`libGL.so.1` loads and 2354 of 3470 entry points resolve from it; then Mesa
`dlopen`s its own `swrast_dri.so`, which needs `libLLVM-6.0.so.1`, which is
reachable on that host only through the cache the bundled `ld.so` is patched to
ignore (E13b). `libGL error: unable to load driver` and then an X error from
`glXCreateContext` -- a display fault, apparently. Same bug as
`CUDA_ERROR_NO_DEVICE` (E44) and `glXCreateContext failed` (E53a). **E77**
measures it on every host and scores the DIAGNOSTIC rather than the outcome:
the outcome depends on how a host packages its driver, but "when this bites,
the process names the library it could not find" holds everywhere.

The second changed how this suite predicts. `eglprobe` fails on 16.04 with the
shims -- and natively:

```
native eglprobe on ubuntu:16.04, no AppImage, no preload, no shim
  EGL_VERSION : 1.4   EGL_VENDOR : Mesa Project
  readback rgba : 0 0 0 255 (want ~64 128 191 255)
  FAILED: the pixel does not carry the colour that was set
```

Mesa 18.0.5 does not produce that pixel on that host at all, so a shim that did
would be inventing one. **E78 and E79 build and run the probes natively, and
E64 and E66 are predicted against that** rather than against a constant. The
shim's claim is transparency; the yardstick for transparency is the host. This
also corrects a hypothesis offered in the issue -- that the readback fails
because the GL and EGL shims do not share dispatch state. There are no shims in
the native run.

### 9.12 A real application, a third dispatcher, and the bug they found

Everything above runs against the host-drivers demo AppImage: `glxgears`,
`vkcube`, and two probes written for this repository. That AppDir bundles a
dispatcher and no Mesa, which is one of the two shapes an AppImage comes in and
not the common one.

The other shape is self-contained: `gtk4-demo`, 272 bundled libraries, its own
Mesa, its own `libEGL_mesa.so.0`, a real GTK4 application. On musl Alpine, with
the shims in `.preload`, it died with `SIGFPE`. Without them it ran.

**The shim was wrong, and had been wrong since it was written.**
`glfwd_host_has_vendor()` asked only whether the HOST had a vendor library.
That is the right question for an AppImage built to use host drivers -- it
bundles a dispatcher and no vendor, so if the host has none either there is
nothing to dispatch to. It is the wrong question for an AppImage that bundles
its whole Mesa: Alpine has no vendor library, the shim concluded "no vendor
anywhere", and forwarded a bundled GTK4 onto Alpine's Mesa. Two Mesas, one
process.

`glfwd_bundle_has_vendor()` asks the other half. If the BUNDLE carries a vendor
library, the bundled dispatcher is what the application was built and tested
against and the shim leaves it alone. That is also what makes this shim safe to
put in every AppImage's `.preload` rather than only in host-drivers ones.

```
E80a  as shipped, no shims          rc=143  (still running when the timeout ended)
E80   gl + egl + gles shims         rc=143  (was 136 = SIGFPE)
E81   target: the bundled dispatcher, because the BUNDLE has its own vendor library
E82gl/egl/gles   3470 of 3470, 44 of 44, 358 of 358 entry points resolved
E83   gtk4-demo called 1 GL, 13 EGL and 46 GLES entry points
```

**E83 is why the GLES shim exists.** GTK4 renders through GLES, not desktop GL.
`libGLESv2.so.2` is a glvnd dispatcher with the same shape as the other two and
it finds its implementation the way EGL does, through a JSON file under
`/usr/share/glvnd/egl_vendor.d`; on a classic host there is none, and without
`gles-fwd.so` those 358 entry points are 358 silent zeros. The table is 358
entries read out of the `libGLESv2.so.2` this AppDir bundles -- which is why
the shim could not exist before this AppDir did, since the generator's one rule
is that the list comes out of the object being replaced.

`libGLESv1_CM.so.1` is not covered. No AppImage available here bundles one, and
that is the whole reason; one `make gles-syms` against an AppDir that has one is
the entire job.

⚠ **Note what found this.** Four synthetic cases, two host classes and 3470
generated trampolines did not. One real application did, on the first run.

---

### 9.13 The IBT property note: emitted after all, and it would be a lie

T-17 recorded that no Debian gcc emits the note, tried three ways. ⛔ **One of
those three ways was recorded wrong.** Re-measured on the same three images,
with a control that must report nothing so that "found none" and "cannot see
one" are distinguishable:

| build | bullseye 10.2 | bookworm 12.2 | trixie 14.2 |
|---|---|---|---|
| `-fcf-protection=full` | none | none | none |
| `-fcf-protection=full -Wl,-z,ibt,-z,shstk` | **IBT, SHSTK** | **IBT, SHSTK** | **IBT, SHSTK** |
| a `.note.gnu.property` block in the source | none | none | none |
| nothing asked for (control) | none | none | none |

Two things follow, and the second is the one that matters.

**The source-emitted note does not survive the link.** `GNU_PROPERTY_X86_FEATURE_1_AND`
is ANDed across every input, and glibc's `crti.o` carries no property on any of
the three images, so a note written by hand in `gl-fwd.c` is dropped. That is
the approach T-17 proposed, and it does not work.

**The linker flag does emit a note, and the note would be false.** Measured on
the object it produces:

| symbol | first instruction | reached by |
|---|---|---|
| `probe_answer` | `endbr64` | a normal call |
| `_init` | `sub $0x8,%rsp` | `DT_INIT`, which `ld.so` calls through a pointer |
| `_fini` | `sub $0x8,%rsp` | `DT_FINI`, the same |

`_init` and `_fini` come from `crti.o` and `crtn.o`. An indirect call landing
on an instruction that is not `endbr64` is exactly what IBT exists to fault on,
so an object marked IBT-capable whose `DT_INIT` target is not `endbr64` is
asserting a property it does not have.

⭐ **So the absence of the note is the linker being right**, not a toolchain
gap to work around. Forcing it with `-z ibt` would trade a real absence for a
false claim, which is the forbidden pattern
[`conventions/forbidden-patterns.md`](conventions/forbidden-patterns.md) calls
"asserting a build property the toolchain does not deliver".

⚠ **What is UNVERIFIED:** whether a CET-enforcing host actually faults on such
an object. No host here enforces IBT, so the fault is reasoned from how IBT
activation works and has not been observed. What IS measured is every row of
both tables above.

The measured consequence for this project: on x86-64 `gl-fwd.so` carries 3478
`endbr64` and no note; on aarch64 it carries none of either, and CET is an x86
feature so that is correct rather than a gap.

⭐ **And the flag accounts for six of those 3478.** Built with
`-fcf-protection=full` removed, the same object has **3472**. The other 3472
are the trampolines' own, spelled as literal bytes in `gl-fwd.c` so the floor's
assembler cannot be too old for them (9.4), and no compiler flag removes those.

| x86-64 `gl-fwd.so` | `endbr64` |
|---|---|
| default build | 3478 |
| built without `-fcf-protection=full` | 3472 |
| aarch64, either way | 0 |

Two things follow.

⛔ **A check that refused a build with no `endbr64` could never have fired**, and
`scripts/verify-artifacts.sh` briefly had one. The trampolines supply 3472
whatever the flag does, so the count says nothing about whether the flag
arrived. It reports the number now and asserts nothing about it.

⚠ **Removing the flag does not remove `endbr64` from the shims**, which matters
to anyone removing it in order to avoid the instruction. It removes six of
them. The instruction is a four-byte NOP on any CPU without CET, so what it
costs on a host that does not implement CET is the four bytes.

---

### 9.14 A guard that could not refuse, and a guard that could not see itself

Deep review pass 1 asked whether every guard added on this branch can actually
refuse. Two could not, and neither was broken in the way it looked.

**The dash ratchet.** `scripts/check-drift.sh` section 4 counts ` -- ` across
every tracked `.md` outside `HISTORY/` and compares it to a number written in
the script. A previous session appended `A sentence -- with a dash.` to
`docs/building.md`, ran the check, read "at the budget", and recorded the
ratchet as broken.

The counter was never wrong. Measured, per commit on this branch, counting
every occurrence the way the check did at the time:

| commit | ` -- ` in tracked `.md` outside `HISTORY/` | pin in the script |
|---|---|---|
| `b162b39` initial | 270 | none yet |
| `bc29fce` front-door rewrite | 236 | set to 236 |
| `e09e128` portable variant | 235 | still 236 |
| `f6d126e` PROGRESS rewrite | 228 | still 236 |

The refusal condition was `count > pin`. At `e09e128` the tree carried 235, so
the planted dash took it to exactly 236, and 236 is not greater than 236. The
check printed the truth. The expectation that it would print 237 assumed the
tree was at the pin, and it was one under.

⛔ **The defect is the slack, and the slack is structural.** Nothing lowered
the pin when the count fell. The script printed a line asking the next reader
to lower it, and three commits running the next reader did not, so a guard
that refuses one dash too many silently became a guard that would accept eight
more before saying anything.

⚠ **A second defect surfaced while writing this section: the counter counted
what the rule exempts.** `docs/conventions/prose.md` says a flag, a literal
inside a code block and a shell comment are all `--` doing their own job. The
counter read the file raw and counted those too. Measured on the tree with
this section in it:

| | count |
|---|---|
| every ` -- ` in tracked `.md` outside `HISTORY/` | 233 |
| inside a fenced code block | 10 |
| inside a code span | 5 |
| actual prose, which is what the rule is about | 218 |

Two consequences, and the second is the one that forced the change. A document
that added a correct shell snippet was refused for being correct. And a
rewrite that traded a prose dash for a code one netted to zero and passed
unseen. ⛔ Together with an exact pin it also made this section unwritable:
recording the planted sentence means putting the planted sentence in a
document. The counter now skips fences and spans, and the pin is the prose
number.

Three runs against the script as it stands, on a tree that is otherwise clean:

```
$ printf 'A sentence -- with a dash.\n' >> docs/building.md
$ sh scripts/check-drift.sh
  FAIL 219 dashes used as punctuation, and the pin is 218.
$ echo $?
1

$ perl -0pi -e 's/ -- / instead /' docs/building.md
$ sh scripts/check-drift.sh
  FAIL 217 dashes used as punctuation, and the pin is still 218.
$ echo $?
1

$ printf '\n~~~\nrun this -- and that\n~~~\n' >> docs/building.md
$ sh scripts/check-drift.sh
  218, at the pin. It may fall, and a fall lowers the pin with it.
$ echo $?
0
```

The first is the rule. The second is what carries the pin down with the count,
and it is the half that was missing. ⭐ **It caught its own author within the
hour.** A rewrite of `docs/integrating.md` dropped one prose dash, the count
fell to 217, and the check refused the commit until the pin came down with it.
That is the whole mechanism working: under the old one-sided version the slack
would simply have widened by one and nobody would have been told. The third is the exemption the rule
always claimed and the check never honoured. `scripts/verify-gates.sh` plants
the first of the three on every run, so the arming is checked rather than
remembered.

**The cited-path check, on the citation shape this repository actually uses.**
Section 2 of the same script reads every repository path a document cites and
opens it. It anchored the path on an opening backtick and required a closing
backtick straight after, which matches `` `scripts/build.sh` `` and nothing
else. The common form here is a command:

```
⚠ The ratchet is `sh scripts/check-prose-dashes.sh`, and it is a ratchet rather
        docs/conventions/prose.md, line 39, before this change
```

No script of that name has ever existed in this repository. The ratchet is
section 4 of `check-drift.sh`. The citation survived the entire branch because
the check that exists to catch a stale citation could not see one written in
front of a command, and the citation it could not see was a citation of
itself.

Widened to allow backtick-free, space-terminated words before the path, and to
drop the closing-backtick requirement so a path followed by its arguments
counts:

| | paths checked |
|---|---|
| before | 80 |
| after | 87 |

Both measured on the tree as it stands with this section in it. Three of the
seven newly visible paths did not exist. One is the real defect
above, the check-prose-dashes name, fixed in `docs/conventions/prose.md`. One
belongs to `Azathothas/TEMPLATE` and is cited at a URL as not being in this
tree. One is `tests/bindprobe`, which is ours, is built from
`tests/bindprobe.c`, and is cited as a command rather than as a file. The last
two are exempt by name.

⚠ **`*` had to enter the path character class in the same change.** Without it
the class stops at the hyphen in `` `src/gl-fwd-*.h` ``, so the wildcard skip
never sees a wildcard and the check reports the truncated stem, everything up
to and including the hyphen, as a file that does not exist. The widened
pattern did exactly that on its first run.

⚠ **And this paragraph is why the check skips a fenced block.** Recording a
broken-path finding means writing the broken path down. The quotation above
sits in a fence and is read as the transcript it is; the two sentences here
name the defect without putting it in citation shape, the way
`scripts/verify-gates.sh` assembles its plants at runtime rather than letting
them sit in the file as literals. Both dodges are the same dodge: a checker
that reads the tree cannot tell a claim from a quotation of a broken one.

**And two refusals that had never been planted at all.**
`scripts/package-release.sh` carries the last two guards before anything is
published: every artefact against its manifest entry, and both archives being
flat. Neither had been made to fire. Both were, against a synthetic build
directory of two files and a hand-written manifest, so no real build was
needed:

| | result |
|---|---|
| a manifest that matches its files | exit 0, `both archives are flat: LICENSE build-manifest.json cross-libc-dlopen.so gl-fwd.so` |
| one artefact edited after the manifest was written | exit 1, `gl-fwd.so does not match its manifest entry`, with both hashes printed |
| the `tar` invocation changed to archive the staging directory instead of its contents | exit 1, `the tar has a path separator in it, so it would extract into a directory`, with the offending listing printed |

⚠ The third is planted in the SCRIPT rather than in the data, and that is the
right place for it: the assertion's own comment says a nested directory "is
exactly the kind of thing that reappears when somebody changes a tar
invocation", so changing the tar invocation is the defect it names.

⛔ **One guard in this family is still unproven:** `release.yml` refuses to
publish a tag whose commit is not an ancestor of the default branch. Firing it
needs a tag, and pushing one publishes a release.


---

### 9.15 The pinned AppImage: which repository, and what a stale pin means

The AppImage suite downloads two binaries from a third party and runs them. The
sha256 pin is what makes the suite's results about a known artefact. Run
[32948154287](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32948154287)
refused with

```
suite: demo.AppImage (x86_64) sha256 is 8f6e390aa36c34f59363b916c29eec3fe95ce931be0c8a89f1e80a43d0981dbe,
expected 712766f8a4dc6b5ea3193ed7bb0282b64c7b781f7334056416edd3d00e8960bd
```

⭐ **The pin did its job.** What follows is about what to do next, which is a
policy question and not a bug.

**Correcting the account of when.** It was recorded here that the assets were
re-uploaded during that run. Measured from the API, they were not:

| event | time |
|---|---|
| run created | `2026-08-26T08:31:03Z` |
| run ended, refusing | `2026-08-26T08:31:41Z` |
| every asset on that release re-created | `2026-08-26T08:32:37Z` |

The re-upload post-dates the run's end by 56 seconds. So the mismatch the run
hit was caused by an EARLIER replacement, and the assets were then replaced
again a minute later. The object the run downloaded no longer exists, so
whether `8f6e390a` was a complete asset or a torn read cannot be established
now. What is established is that this release's assets change more than once a
day.

**Which repository.** `pkgforge-dev/Anylinux-AppImages` is the upstream:
`fork: false`, 234 stars. `Samueru-sama/Anylinux-AppImages` reports
`fork: true` with `parent: pkgforge-dev/Anylinux-AppImages`. The suite was
taking both assets from the fork.

⚠ **One of the two cannot move, and the reason is what is being measured.**

| asset | upstream | fork |
|---|---|---|
| `gtk4-demo-<arch>.AppImage` | published | published |
| `vkcube+glxgears-host-drivers-demo-<arch>.AppImage` | **not published** | published |

A code search for `host-drivers` across the upstream returns 0 results. The
upstream's `vkcube+glxgears-demo-<arch>.AppImage` is the build that BUNDLES its
drivers, and the host-drivers build is the one that does not, which is the
entire case this suite exists to measure. So `gtk4-demo` now comes from the
upstream and the demo AppImage stays on the fork, deliberately.

**The policy, and why it is the one that was available.**

| option | verdict |
|---|---|
| pin to an immutable release | ⛔ not available. Measured: BOTH repositories publish exactly one release each, and both are tagged `demo` |
| mirror the asset into this repository | ⛔ refused by `scripts/check-drift.sh` section 2c, which rejects any tracked `*.AppImage` by shape |
| mirror to a release of our own | needs a published release, and nothing has been published yet |
| ⭐ re-pin as a maintained act, recorded and reviewed | adopted |

⛔ **A re-pin is a decision, so the refusal now says what the decision is
about.** The old message printed one sentence whatever had happened, and three
different things can disagree: the pin, the bytes that arrived, and the digest
the release publishes today. `scripts/suite-lib.sh` reads the third from the
release API, which needs no download, and names the case. All five paths
proven, unpiped, exit codes read directly:

| what disagrees | verdict printed | exit |
|---|---|---|
| nothing | `sha256 ok` | 0 |
| pin only, bytes match the published asset | `UPSTREAM RE-UPLOADED IT` | 1 |
| bytes only, published asset still matches the pin | `THE DOWNLOAD IS WRONG, NOT THE PIN` | 1 |
| all three differ | `NEITHER MATCHES` | 1 |
| API unreachable | cause not established, refuse anyway | 1 |

The second row was proven against the real asset: the pin that failed in that
run, against the file as it stands today.

⚠ **The four pins were recomputed from the bytes, not copied from the API.**
Each was downloaded and hashed here, and each then agreed with the digest the
release publishes, which is a cross-check rather than the source.

⛔ **`docs/ground-truth.md`'s inventory of the demo AppImage was taken against
the OLD binary**, sha256 `712766f8...`, 10 736 056 bytes. The newly pinned
build is 10 817 560 bytes. Its bundled glibc version, its stub library set and
its export counts are therefore UNVERIFIED against the artefact the suite now
runs. The suite re-extracts and re-asserts on every run, so the next completed
run is what settles it, and a changed answer is a finding rather than a
regression.

---

### 9.16 What this branch stopped measuring

Deep review pass 2 asked one question: what did this branch stop measuring?
Two answers, and neither showed up as a failing case, because both of them
went green.

**1. The ARM runner arrived and section P did not notice.**

`.github/workflows/gates.yml` added `ubuntu-24.04-arm` with a reason written
into the matrix: it is "the row where CI is STRONGER than the machine this
project was built on", because "the aarch64 trampolines have only ever run
under qemu-user, which emulates the instructions and not a memory model".

Section P of `experiments/30-run-tests.sh` is the case that runs those
trampolines. It opens by saying "This machine is x86_64 and there is no
aarch64 silicon to borrow", which was true when it was written, and it
cross-compiles with `aarch64-linux-gnu-gcc` and runs the result under
`qemu-aarch64-static`. It does that unconditionally.

⛔ **So on the aarch64 runner, E76 and E76b ran an aarch64 binary under an
aarch64 emulator on an aarch64 CPU**, and passed. Measured, from the aarch64
evidence job of run
[32950783301](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32950783301):

```
-- P. the aarch64 trampolines, RUN -----------------------------
  E76    MATCH predicted=OK    OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12] second-call-identical=yes absent-returned=0
  E76b   MATCH predicted=OK     [tgt-fwd.so] >> libtgt.so: 5 entry points, none resolved yet
```

Two green cases, on the one host where the emulator is the thing standing
between the measurement and the point of it. The branch bought real silicon
and then declined to stand on it.

Section P now picks its vehicle from the host and PRINTS which one it used,
because a reader holding one log has no other way to tell:

| host | compiler | vehicle |
|---|---|---|
| aarch64 | `gcc` | native. No emulator in the path |
| x86_64, cross toolchain and qemu present | `aarch64-linux-gnu-gcc` | `qemu-user`. Userspace emulation, not a memory model |
| x86_64, neither present | none | E76 and E76b SKIP, naming what is missing |

⚠ The predictions did not change. Same case ids, same expected exit, same
needles. Only the vehicle did, and the stage no longer installs an emulator
for the architecture it is standing on.

**2. A marker that stopped being read, and four documents that did not.**

The markers were removed on this branch and the feature is on by default. Two
of the places that explained behaviour by the marker were comments on a case:

```
# already carries .foreign-dlopen-enabled -- quick-sharun's spelling of the
# marker, still accepted -- so the feature turns itself on
        experiments/40-appimage.sh, E40, before this change
```

Nothing in `src/` reads that file. Measured: `git grep` for the name across
`src/` and `tests/` returns one hit, and it is a comment in `src/cld-env.h`
saying the marker is gone.

⭐ **E40 kept passing, for a reason its own comment did not give.** Its claim,
that this is the case which forces nothing, did not weaken. It got stronger:
the feature turning itself on with no marker present is a larger statement
than it turning itself on because a marker is present. That is why nobody
noticed, and it is the shape worth naming. A case whose stated mechanism has
been replaced by a better one reads exactly like a case that is fine.

Four places carried the stale claim, and `docs/AGENTS.md` carried it in a
table of names that must not be renamed on pain of turning E30, E37a and E43a
into silent passes. That protection is real and it belongs to two other
things, measured on the tree as it stands:

| name | still load-bearing? |
|---|---|
| the AppDir's dispatcher slot | yes. `.preload` names it and our build is copied into it. ⚠ Its NAME is not load-bearing and must not be spelled by us: 9.17 has upstream changing it |
| the `ANYLINUX_*` env spelling in `experiments/40-appimage.sh` | yes. 13 call sites, none touched by this branch, and upstream's binary understands no other spelling |
| `.foreign-dlopen-enabled` | ⛔ no. Nothing in `src/` reads it |

⚠ Whether upstream's own binary still reads the marker is NOT measured here.
No case depends on the answer, because every arm sets the variable explicitly.

---

### 9.17 Upstream shipped this project, and the AppDir changed shape

Re-pinned to the current asset, the suite got further and then refused on both
architectures, in run
[32951892766](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32951892766):

```
demo.AppImage (x86_64) sha256 ok
==> debian:trixie-slim  (41-extract.sh)
cp: cannot stat 'AppDir/lib/foreign-dlopen.so': No such file or directory
suite: extraction failed
```

⭐ **A sha256 pin says the bytes are the ones somebody reviewed. It says
nothing about the layout inside them.** The layout moved.

**What the pinned AppImage now contains.** Extracted and measured here:

| `AppDir/lib` | |
|---|---|
| `cross-libc-dlopen.so` | 51 608 bytes. Debug tag `[cross-libc-dlopen]`, and it reads both the `CROSS_LIBC_DLOPEN_*` names and the `ANYLINUX_*` aliases. It is a build of THIS project |
| `gl-fwd.so` | 566 608 bytes, SONAME `libGL.so.1`. This project's forwarding shim |
| `egl-fwd.so` | 27 200 bytes |
| `gles-fwd.so` | 78 864 bytes |
| `foreign-dlopen.so` | ⛔ gone |

⛔ **Upstream adopted this project and renamed the slot to it.** The one file
the whole A/B replaces used to be `lib/foreign-dlopen.so` and is now
`lib/cross-libc-dlopen.so`. `experiments/41-extract.sh` reads the name out of
the AppDir and writes it to `.cld-slot`; `40-appimage.sh` takes it from there
rather than either file spelling it. Both spellings are accepted by name, the
one that was found is printed, and an AppDir with neither is a refusal that
lists what is actually in `lib/`. A guess would be worse than a refusal: the
A/B is one `cp` into one path, and a wrong path makes both arms identical and
reports them agreeing.

⚠ **The rename is the loud half. The quiet half is `.preload`.**

| | |
|---|---|
| recorded in `ground-truth.md` | `path-mapping.so`, `anylinux.so`, `cross-libc-dlopen.so` |
| shipped by the pinned build | the same three, then `gl-fwd.so`, `egl-fwd.so`, `gles-fwd.so` |

`41-extract.sh` saved the shipped `.preload` as the baseline that every later
case restores from before appending the one shim under test. With this project's
shims already in that list, every case whose whole point is a shim's ABSENCE
would have run with upstream's copy of it present, appended a duplicate line,
and passed. ⛔ Nothing would have reported anything: no MISMATCH, no skip, no
warning. The suite would have gone green measuring the opposite of its claim.

Two files now, and the difference between them is the point:

| file | what it is |
|---|---|
| `.preload.shipped` | what the AppImage ships, byte for byte. A record. Never restored from |
| `.preload.baseline` | the same list with this project's own forwarding shims removed. What the cases restore from |

⭐ **The derived baseline is exactly the old shipped list**, which is the
check that it reconstructs the contrast the cases were written against rather
than inventing one:

```
dispatcher slot: lib/cross-libc-dlopen.so
shipped .preload:
    path-mapping.so
    anylinux.so
    cross-libc-dlopen.so
    gl-fwd.so
    egl-fwd.so
    gles-fwd.so
  ⚠ removed from the restore baseline: gl-fwd.so egl-fwd.so gles-fwd.so
AppDir: 94 libraries, bundled glibc 2.44
```

That runs on every extraction. A suite that edits the artefact under test and
does not say so is worse than one that refuses.

**The inventory, re-measured against the pinned build.**

| row | verdict |
|---|---|
| bundled glibc 2.44 | unchanged, confirmed |
| legacy split libs present, `libanl.so.1` absent | unchanged, confirmed |
| `.foreign-dlopen-enabled` present, 0 bytes | unchanged, confirmed |
| `gconv/` bundled, beside `locale/` and `vkmark/` | unchanged, confirmed |
| `.preload` contents | ⛔ CHANGED, above |
| the dispatcher's filename | ⛔ CHANGED, above |
| bundled `cross-libc-dlopen.c`, 24 785 bytes | ⛔ GONE. The only `.c` in the AppDir is `.anylinux.c`, 20 731 bytes, a `linuxdeploy-plugin-checkrt` derivative belonging to `anylinux.so`. It names this project 0 times |
| stub export counts 13, 4, 6, 2 | ⚠ NOT RE-ESTABLISHED |
| 51 sonames | ⚠ NOT RE-ESTABLISHED |

⚠ **Why two rows are UNVERIFIED rather than corrected.** Four counting methods
were tried against the new binary and none reproduces 13, 4, 6, 2:

| method | libpthread | libdl | librt | libutil |
|---|---|---|---|---|
| `objdump -T`, `DF .text` | 12 | 3 | 5 | 1 |
| the same, versioned only | 12 | 3 | 5 | 1 |
| `objdump -T`, every global or weak | 28 | 10 | 14 | 6 |
| `nm -D --defined-only` | 24 | 6 | 10 | 2 |

Every one of the first method's four numbers is exactly one below the recorded
value, which is the signature of a counting difference rather than four
independent changes. The old binary no longer exists, so the method cannot be
tested against it, and artefact and method cannot be separated. ⭐ The claim
those numbers exist to support does hold: all four are single digits, so they
are stubs. The soname total is the same shape of question, measured at 49
distinct sonames over 55 regular files and 35 symlinks.

⛔ **The A/B's control arm no longer contrasts, and that IS the finding.**

The "as shipped" arm used to be upstream's own shim, which could not load a
host driver. It is now a build of this project, older than the working tree,
still carrying the `ANYLINUX_*` aliases this branch removed. E30 and E37a are
the controls for that arm, and they are what make the patched arm a
measurement rather than a coincidence.

⚠ **Read their predictions carefully, because the log line is misleading on
its own.** Both are `predicted=OK`, which is about the exit status: the
program is expected to run cleanly. What they assert is the NEEDLE, and the
needle is the complaint being reproduced:

| case | asserts the output contains |
|---|---|
| `run E30 OK "NO-DEVICES" probe_verdict 1` | `NO-DEVICES` |
| `run E37a OK "zero accessible devices" render_verdict vkcube --c 20` | `zero accessible devices` |

So a MISMATCH here means the as-shipped arm found a device. Run
[32953461170](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32953461170),
x86-64, the suite's first completed run:

```
E30    MISMATCH predicted=OK    DEVICES  (  device[0] : llvmpipe (LLVM 20.1.8, 256 bits))
E37a   MISMATCH predicted=OK    Selected GPU 0: llvmpipe (LLVM 20.1.8, 256 bits), type: Cpu
```

Both arms now work, so neither case can distinguish them. ⭐ **The right
response is not to flip the predictions.** A control that has stopped
contrasting has stopped measuring, and rewriting it to expect success would
convert two controls into two cases that pass whatever the shim does, which is
the exact shape this repository calls a silent pass.

⚠ The honest control for "the feature is absent" is an AppDir with NO
dispatcher in `.preload`, not an AppDir carrying somebody else's. Choosing
that, or something else, changes what the suite claims about upstream and is a
decision rather than a repair. It is left open deliberately.

**Two further MISMATCHes, and one of them could not say why.** E33 and E34
reported `feature off: 3 / 0 load` and `feature on : 0 / 0 load` on the musl
host and the same zero total on the glibc one. A total of 0 means the
feature-ON corpus run produced no verdict line at all, so both cases were
scored against nothing. ⛔ **Its stderr went to `/dev/null`**, which is T-13's
shape for the third time in this tree, and the reason was in the stream that
had been discarded. It is captured now and printed when, and only when, the
run produces no verdict line.

E49 went MISMATCH on aarch64 with one truncated line of preamble, for the same
family of reason: `experiments/40-appimage.sh`'s `run` printed a 96-column
summary of a failure where `30-run-tests.sh`'s has printed the whole captured
output since T-13 closed. Both harnesses do now. ⛔ **E50's assertion is left
alone until E49 can be read.** It requires exactly two live musl-against-glibc
ABI hazards and aarch64 measured zero, which would be a genuine architectural
difference worth recording, except that E49 failed in the same stage and a
hazard count taken from a crossing that did not happen measures nothing.

---

### 9.18 aarch64 has a live ABI hazard x86-64 does not, and the probe aborted on it

E49 was unreadable until `experiments/40-appimage.sh` gained the full MISMATCH
dump. With it, the cause is the last four lines of the case's own output, run
[32954726201](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32954726201),
aarch64:

```
  T1.6 -- mutex and condition variable across the boundary
    ok   guest locked+unlocked a host mutex   returned 0
    ok   and left it unlocked
    ok   guest allocated a mutex with its own sizeof
    ok   host locked the guest's mutex        returned 0
malloc(): invalid size (unsorted)
Aborted (core dumped)
(exit 134, wanted OK, needle: ABI CROSSING PASSED)
```

⭐ **The cause is in the same dump, eleven lines earlier**, in the size table
that T1.7a prints before any crossing is attempted:

| | musl guest | glibc host | |
|---|---|---|---|
| `pthread_mutex_t` | 40 | 48 | ⛔ diverges on aarch64 |
| `pthread_mutex_t` | 40 | 40 | agrees on x86-64 |

⛔ **The overflow is inside the GUEST, and it needs no crossing at all.**
That is worth stating precisely, because the first reading of this was wrong
and the fix built on it did not work. `abi_new_mutex()` in
`tests/abi-guest.c` is four lines:

```
pthread_mutex_t *m = malloc(sizeof *m);        /* the GUEST's 40 */
if (!m) return NULL;
if (pthread_mutex_init(m, NULL) != 0) ...      /* resolves to OURS, writes 48 */
return m;
```

The guest allocates its own size. Its `pthread_mutex_init` is glibc's, because
making every reference in the guest resolve to this process's libc is the
entire point of the thing under test. So glibc writes 48 bytes into a 40-byte
allocation before anything is handed back, and the host's `free()` further down
is merely where glibc notices.

⚠ **Whether it is noticed depends on allocator rounding, and the write is
real either way.** Measured on x86-64 with a guest planted to report and
allocate eight bytes short: glibc rounds a 32-byte request up to a 40-byte
usable chunk, the overflow lands in that padding, and nothing aborts. Planted
32 bytes short instead, it escapes the padding and aborts. ⛔ A silent one is
the worse outcome of the two, and it is the one a size pair closer together
produces.

⛔ **This is a real hazard, not a harness artefact:** no loader can make a
40-byte allocation hold a 48-byte mutex, and the same shape reaches any
musl-built object that allocates a `pthread_mutex_t` with its own `sizeof` in
a glibc process on aarch64.

**The measured contrast, one run, both architectures:**

| | x86-64 | aarch64 |
|---|---|---|
| E49 | MATCH, `ABI CROSSING PASSED: 26 checks, 0 failed` | ⛔ MISMATCH, `exit 134` |
| E50 | MATCH, 2 live hazards: `regexec`, `nftw` | MISMATCH, 0 |

⚠ **E50's zero was not a finding.** The abort came before the hazard scan, so
the count was taken from a process that had already died. That is why E50's
assertion was left alone: a hazard count from a crossing that did not happen
measures nothing, and pinning aarch64 to zero would have recorded the crash as
an architectural virtue.

**The probe declines the CALL now, and reports it.** `tests/abi-host.c`'s own
header already says T1.7 writes divergent structs behind a guard band "because
an overrun that only happens on success is the most misleading result
available". T1.6 had the same overrun and no band, and only x86-64 had ever run
it, where the sizes happen to agree. It is reported the way every other size
divergence in that file is reported, through a `DIFF` line and a `LIVE HAZARD`
explanation rather than through `ok()`, because a hazard is not a failed check:
it is a thing no loader can fix.

⚠ **The first version of that guard wrapped the wrong thing**, and this is
recorded rather than quietly corrected because the failure it produced looked
exactly like success. It guarded the host's `pthread_mutex_lock`, which is the
crossing the case is about, and left `g_newmtx()` being called. Run
[32955888055](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32955888055)
printed the hazard, in full, and then died at the same `free()` with the same
`exit 134`. ⭐ It did move E50 from 0 live hazards to 1, because the hazard
line was printed before the abort, which is precisely the kind of partial
improvement that reads as a fix.

⛔ **Proven by reproducing the abort on x86-64, not by reasoning about it.**
A guest was rebuilt to report AND allocate a short mutex, which is what a real
musl guest does on aarch64. Both hosts were built from the same tree and run
against the same planted guest:

| guard | exit |
|---|---|
| wrapping the host's lock, the first attempt | ⛔ **134**, SIGABRT. `g_newmtx()` is still called and the overflow is inside it |
| wrapping the call, as it stands | **0**, `ABI CROSSING PASSED: 25 checks, 0 failed` |

⚠ The delta has to be large enough to escape glibc's chunk rounding for the
abort to appear at all, which is the same caveat as above. At eight bytes short
both hosts exit 0 and the difference is visible only in the output: the old one
still prints `ok guest allocated a mutex with its own sizeof`, because it
called the function that does the overflowing write.

The reported form, from the same runs:

```
    ok   and left it unlocked
    DIFF a mutex the guest allocates and inits host=40 guest=8
         LIVE HAZARD: pthread_mutex_t is 40 bytes here and 8
         there. The guest allocates its own size and calls
         pthread_mutex_init, which resolves to OURS and writes this
         size into it. NOT PERFORMED: on this pair it is an
         out-of-bounds write inside the guest, and the allocator
         aborts the process on the next free.
    ok   guest signalled a host condvar       guest signal returned 0, host wait returned 0

ABI CROSSING PASSED: 25 checks, 0 failed
```

and the same binary against an unplanted same-libc guest still reports
`ABI CROSSING PASSED: 27 checks, 0 failed` with the crossing performed, so the
guard is not simply always firing. ⭐ The run reaches the end now, which matters beyond E49: T1.7b and
E50's hazard scan are downstream of the abort and had never executed on aarch64
at all.

⚠ **E50's `2` is an x86-64 number and aarch64's is UNVERIFIED.** It will not be
zero, because the mutex hazard alone is one, and the aarch64 size table also
shows `regoff_t` at 8 against 4 and the `FTW_*` constants each off by one. The
number is left unpinned until a completed aarch64 run states it. Pinning a
guess is how a measured figure becomes an estimate.

---

## 10. Measured versus assumed

**Measured:** every table and quoted output above, plus `sh scripts/run-evidence.sh`
(53/53 on x86-64, 50/50 on aarch64), `sh scripts/run-appimage.sh` (45/45 glvnd glibc, 40/40 musl with five
named skips, 26/26 on each pre-glvnd glibc host, 7/7 on the gtk4 stage), `tools/gap.py --fetch`, the eight-distro inventory, the AppImage inventory,
the corpus test, and the five-distro `ld.so.cache` survey in
`ground-truth.md`.

**Assumed or UNVERIFIED:**

- The tests still skipped above: hardware **Vulkan** and the DRM-native drivers
  (T5.1), the proprietary **graphics** driver (T5.2), and aarch64 hardware
  (T5.3). Each names what would unblock it, and none of them is unblockable
  from this machine. T3.3, `glxgears` on a musl host, is no longer among them.
- **Hardware GL on the CLASSIC-Mesa path has never run here, and the reason is
  structural.** The only GPU route on this machine is Mesa's `d3d12` Gallium
  driver over `/dev/dxg`, which needs Mesa >= 21; every glibc distro at Mesa >=
  21 uses libglvnd, and the classic holdouts are musl distros that do not build
  `d3d12`. Measured: alpine:3.22 ships no `d3d12_dri.so`, and `/usr/lib/wsl/lib`
  ships `libd3d12.so`, `libdxcore.so` and CUDA but no GL, GLX or EGL at all. It
  is reported working on an RX 580 from outside
  (by @Samueru-sama); that
  is not reproduced here and is not adopted as if it were.
- **A GLES application has been measured, a GLES-on-classic-host REPAIR has
  not.** E83 shows gtk4-demo calling 46 GLES entry points, but that AppImage
  bundles its own vendor library, so `gles-fwd.so` forwarded to the BUNDLED
  dispatcher. No AppDir here is both GLES-bundling and host-drivers, so the
  case the GLES shim was written for -- a classic host with no EGL vendor -- is
  covered by construction and by the GL and EGL cases that share its code path,
  not by a measurement of its own.
- **The aarch64 trampolines RUN, under qemu-user, and have never touched
  aarch64 silicon.** This entry used to say "assembled, never run", which is a
  weaker claim, and `make gl-fwd-qemu-check` plus E76/E76b replaced it: qemu
  executes an aarch64 binary on an x86_64 kernel in userspace, and everything
  under test is userspace -- the trampoline, the register-saving resolver,
  ld.so binding a `DT_NEEDED` to a preloaded object with the same SONAME, and
  `dlopen`.

```
t_ints:
    bti  c
    mov  w17, #0x0          # the index, in IP1 because x16 is the branch reg
    adrp x16, glfwd_tab
    ldr  x16, [x16, #272]
    br   x16

E76   OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12]
      second-call-identical=yes absent-returned=0
E76b  ABSENT entry point called: t_absent
```

  What remains UNVERIFIED is aarch64 **hardware**: qemu-user emulates the
  instructions, not a real memory model, and no Mesa has been driven through
  these trampolines on an ARM machine.
- **The `_glapi_tls_Dispatch` case that motivates `gl-fwd`'s `RTLD_GLOBAL` was
  not reproduced on a shipping Mesa here.** The mechanism is measured (E54,
  E55); the report that a real DRI driver still relies on it is against Mesa
  10.1 and comes from outside this repository. Alpine 3.22's Mesa has no
  separate `libglapi.so.0`, and Alpine 3.15's `swrast_dri.so` carries the
  `DT_NEEDED` edge. Section 9.5.
- **1097 of 3470 GL entry points are unresolvable on Alpine's Mesa** and
  forward to a stub that returns zero, which matches what an application would
  get natively there. This entry used to end "but no application here has
  called one", which was true and unmeasurable. It is measured now: a call to
  one prints a line naming it, and `glprobe` reaches **zero** of the 1097 while
  calling 15 of the 3470 (9.8). What is still UNVERIFIED is any application
  that DOES reach one -- none of the four measured here does, so the
  zero-returning path is exercised by construction and by E72, not by a real
  program hitting it.
- **T1.6 was not run under a thread sanitiser.** The crossings are exercised and
  bounded by a timeout, which catches a broken binding; it does not catch a race
  that happens not to fire.
- **The generated shim's stub-only symbols have never been called.** Their abort
  path is exercised by construction, not by a driver reaching it.
- **The `--host-dir` override and the symlink farm are tested in containers,
  not on a real desktop** where `XDG_RUNTIME_DIR` is a user-owned tmpfs. The
  permission model there is UNVERIFIED.
- **Design R has never run a GPU workload under an AUTO decision.** It now
  drives both a Vulkan device and the CUDA round trip under the switched runtime
  (E51, E52, section 7.6), but the switch is forced with `CROSS_LIBC_DLOPEN_RUNTIME=host`:
  no host here has a glibc newer than the bundled 2.44, so auto correctly
  declines every time. The path where auto chooses to switch AND a driver runs
  is still UNVERIFIED, and needs a host with a newer glibc than the bundle.
- A 32-bit or aarch64 build is UNVERIFIED.

---

## 11. Known unfixed and out of scope

**Case 3, a glibc-built host library loading into a musl process, is out of
scope and not addressed.** The packaging always bundles glibc deliberately,
because musl would lose the proprietary NVIDIA driver. Anyone who needs case 3
should use [pg83/solo](https://github.com/pg83/solo), which solves it with its
own ELF loader (`lib/elf_loader.cpp`, 2707 lines) and a glibc-to-musl ABI bridge
(`lib/glibc_shim.cpp`, 5948 lines).

⚠ **A previous version of this paragraph described solo's CI from reading rather
than from checking, and one of its numbers was wrong.** Verified against solo's
own `.github/workflows/ci.yml` at commit `79451211`: nine jobs on every push and
pull request -- Alpine/musl, Fedora/GCC, Ubuntu/Clang, Ubuntu/arm64, a qemu
kernel boot, NixOS/lavapipe, and Termux/bionic on both architectures -- plus
`abi_diff`, `secure_test`, `rootfs_smoke`, `pthread_test`, `vulkan_test` and
coverage upload. The corpus manifest `tst/corpus_x86_64.json` lists **1176
packages** (aarch64: 1172); the "2100 objects" figure previously stated here is
not what that file says, and the object count after unpacking was not measured.
The full sweep is in
[`../HISTORY/references/solo-findings.md`](../HISTORY/references/solo-findings.md).

⛔ **A musl object cannot allocate and initialise its own `pthread_mutex_t` in
a glibc process on aarch64, and nothing here fixes it.** musl's is 40 bytes
there and glibc's is 48, so the object allocates 40 and the `pthread_mutex_init`
it reaches writes 48. ⚠ No crossing is involved: the overflow is inside the
musl object, on its own allocation, and it happens because the loader did
exactly what it is supposed to do. It is measured, it is architecture-specific,
and x86-64 does not have it because both are 40 there. Section 9.18 has the
transcript and the size table. This is the shape the whole approach cannot
address: the loader can make every reference resolve to one libc, and it cannot
change a size the object compiled in.

Also not delivered: NVIDIA's glibc-only userspace on a musl process, static musl
binaries with GPU access, bridging manylinux wheels into Alpine, and distroless
containers reaching host NSS or PAM.

Two designs were evaluated on paper and both rejected, with evidence, in
[`rejected-designs.md`](rejected-designs.md).
`dlmopen` into a private namespace is impossible (E9 measures it failing
identically to plain `dlopen`). A private ELF loader costs about 2700 lines,
still needs a shim, and buys isolation for a collision surface measured at three
sonames.

---

## 12. Residual risk

1. **The version-trap set is per-libc and computed, not universal.**
   `version-compat.c` covers what `tools/version_traps.py` finds in the libc it
   is audited against. A glibc that adds a trap after this was built is caught
   by `make traps` (E26) only if someone runs it. The audit is a build target,
   not an automatic gate, and nothing regenerates it on a bundled-glibc bump.
   Same class as risk 6.
2. **Two of the glibc-vs-musl hazards are live, and no loader can fix them**
   (T1.7, section 7.4). The list is no longer six unknowns: every named field of
   every divergent struct sits at the same offset, so `rusage`, `sched_param`
   and `stat` cross harmlessly, and passing host-allocated storage to the guest
   is safe because glibc's implementation writes glibc's layout. What breaks is
   a musl-built object reading a glibc-filled struct back at its own stride --
   `regoff_t` is 4 bytes on glibc and 8 on musl -- and comparing against its own
   `FTW_*` values, which are off by one. Nothing here reaches either, and
   nothing here would notice if it did except E50, which is why E50 asserts the
   count rather than merely printing it. An offset compiled into an object is
   not reachable from a preload; the only real mitigations are not loading such
   an object or switching the whole runtime.
3. **Switching to the host runtime abandons the bundle-everything guarantee.**
   Real, deliberate, surfaced and overridable, but real.
4. **The generated shim is bounded by construction.** It covers what existed
   when it was generated. A symbol invented afterwards is the host-runtime
   switch's job, and on a musl host there is no host-runtime switch, which is
   why the musl row of the decision matrix has no escape hatch. Its
   forward-compatibility risk is small, because musl's exported surface grows
   slowly and glibc is very nearly a superset, but it is not zero.
5. **`at_quick_exit` returns failure rather than registering a handler.**
   glibc's real one runs handlers on `quick_exit()` only; approximating it with
   `__cxa_atexit` would run them on normal exit too, which is worse. Callers
   that ignore the return value will silently not get their handler.
6. **The stale-shim hazard.** If the bundled glibc is upgraded without
   regenerating `forward-shim.c`, the shim would interpose over symbols libc now
   provides. The manifest records the floor and `make shim` regenerates, but
   nothing enforces regeneration at build time.
7. **The forwarders are process-wide.** A bundled library's own
   `pthread_cond_init@GLIBC_2.3.2` reference also lands in `version-compat.c`,
   because glibc lets an unversioned definition satisfy a versioned reference --
   that is how `LD_PRELOAD` interposition has always worked. It then forwards to
   the same default definition it would have reached directly, so behaviour is
   unchanged and the cost is one indirect call. The case this would get wrong is
   an object that genuinely wants an obsolete version: glibc 2.2.5-era condition
   variables, 2003 or earlier. Nothing that ships in an AppImage does, and
   nothing was found that does, but this is an assumption rather than a
   measurement.
8. **Library discovery, not `dlopen`, is what breaks a host driver most often
   here, and two of the three assemblers are still hardcoded lists.**
   `src/runtime-select.c` now derives its directories from `/etc/ld.so.conf`
   (section 7.3). Sharun does not yet -- the patch exists and is unapplied --
   and `cross-libc-dlopen.c` deliberately never will, because finding libraries is
   `ld.so`'s job. Until the patch lands, any host that puts a driver somewhere
   only the cache knows about will fail in a way that does not mention a
   library: `CUDA_ERROR_NO_DEVICE` (E44) or `glXCreateContext failed` (E53a).
   Both were measured on this machine, on drivers people actually use.
9. **On a musl host, "the feature off" is not a safe fallback.** Measured under
   the demo AppImage's own AppRun on Alpine: with `CROSS_LIBC_DLOPEN=0`
   and a search path that reaches `/lib`, the bundled glibc `ld.so` finds
   `libc.musl-x86_64.so.1`, loads it, and the process ends up with **two libc
   families initialised** (`calling init:` names both). It renders, which is
   worse than failing, because rule 3 of the design says exactly one libc family
   may ever be in a process and E8/E9 measure why. With the feature on, only
   glibc is initialised (E35). This is upstream behaviour, not something this
   work introduced, and it is not fixed here -- it is recorded because "it
   worked with the feature off" is not the reassurance it looks like.
