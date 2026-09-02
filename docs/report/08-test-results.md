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

`sh scripts/run-evidence.sh` reports **63/63 predictions held on x86-64** and
**60/60 on aarch64**. The x86-64 total was measured at the change that added
E75c through E75f; the aarch64 runner runs the same table, so its total is the
x86-64 total minus the three skips below, and CI re-runs both on every push.
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
63 minus 3 is 60, and no case is missing for a reason nobody wrote down.

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
| E75c / E75d / E75e / E75f | a shim with no target serves each name from the provider behind it in the lookup order; the no-preload control; the log line pinning the fallthrough; the same in EAGER mode |
| E76 / E76b | the aarch64 trampolines and resolver RUN, under qemu-user, forwarding and absent paths both |

E69 through E76b are built from the **real** `src/gl-fwd.c` with a five-name
table rather than from a copy of the resolver, because a copy is a thing that
drifts from what ships.

### Tier 1b, the AppImage end-to-end suite

`experiments/appimage.ps1` runs real AppImages against real host drivers on
five stages:

| stage | what it is | result |
|---|---|---|
| `alpine:3.22` | musl, classic Mesa, the case the complaint is about | **40/40**, 5 named skips |
| `debian:trixie-slim` | glibc, glvnd, the regression case | **45/45**, no skips |
| `ubuntu:14.04` | glibc 2.19, classic Mesa 10.1, no Vulkan | **26/26**, 19 named skips |
| `ubuntu:16.04` | glibc 2.23, classic Mesa 18.0.5, no Vulkan | **26/26**, 19 named skips |
| gtk4-demo on `alpine:3.22` | not a host, but a different APPIMAGE, self-contained, a real GTK4 application | **7/7**, no skips |

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
device, because Mesa 10.1 predates Vulkan entirely, plus E53a/E53/E53b for the same
reason as Alpine, plus E59/E60, whose tools need python 3.6 and which measure
the BUNDLE rather than the host, so the other stages establish them. The
fourteenth is **E67**, a Vulkan case that lives in the OpenGL section because
what it measures is that the GL shims cost the Vulkan path nothing; it was
guarded where the section is rather than where the case is, and on the first
pre-glvnd run it reported MISMATCH for a capability the host does not have. On a
machine with no GPU at all the driver's own capability probe turns E41-E53 into
skips as well, and the suite still passes. That is the point of probing rather
than assuming.

**E38 is retired rather than renumbered.** It was `glxgears`, run on a host with
a libglvnd vendor library and SKIPPED on one without, and its skip reason
carried a verdict, "no loader shim can supply a file the distribution does not
ship", that was never tested and was wrong. E61 and E62 replace it by
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
| T3.5 | EGL on a host with no glvnd EGL vendor | **PASS where the host's own EGL can do it.** `eglprobe` goes from `EGL_NO_DISPLAY` to a working surfaceless context on Alpine and on Ubuntu 14.04 (E65, E66). On Ubuntu 16.04 it does not, and it does not NATIVELY either, with no AppImage in the process (E79), so the shim is reproducing the host rather than failing. 9.11 |
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

Five of these, T1.3 through T1.7, were SKIPPED and UNVERIFIED for the life of
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

---

[REPORT index](README.md) | [previous](07-closed-source-driver-and-abi.md) | [next](09-the-second-boundary.md)
