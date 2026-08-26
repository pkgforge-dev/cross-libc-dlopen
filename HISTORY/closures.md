# Closed, with the evidence

Eight limits were named as open. Seven closed, each with a record of what
was measured to close it; the eighth is blocked by hardware and lives in
[`TODO/blocked.md`](../TODO/blocked.md).

*Moved verbatim from `CONTINUE.md` when that file was dissolved into the
work record. The wording is the original: a trap written down in one
sentence is a trap the next person does not walk into.*

*One mechanical edit was made on the way in: a redundant check-mark before the
word CLOSED, and from 8 closure-record headings, 16 places in all, which the prose convention does not allow and which said
nothing the word beside it did not already say. No wording changed.*

### 4.0 START HERE: the priority for the next session

The question asked of the last session was: **did you get this to work on
systems without glvnd?** The honest answer is **yes, but**, and this subsection
is the list of "buts" in the order they should be closed. Everything else in
section 4 is blocked by hardware or by packaging. This list is not: every item
on it is work that can be done on this machine, and each one narrows a claim
that is currently wider than its evidence.

**What is actually demonstrated.** On alpine:3.22 and alpine:3.15 -- musl,
classic Mesa, no `libGLX_<vendor>.so.0` anywhere -- the demo AppImage's bundled
glibc 2.44 drives the host's GL: `glxgears` renders (E62), `glprobe` clears to a
known colour and reads `64 128 191 255` back out of the framebuffer (E64), and
`eglprobe` gets a working surfaceless context (E66). On a glvnd host all three
are unchanged, so the shim is transparent where GL already worked. That is a
real result and it is not in doubt.

**What is not demonstrated, in priority order.** ⭐ The titles below are how
each item has been referred to, so they do not change; what an item's row says
after it closes is written under the table in 4.0.1, including where a premise
in the row turned out to be wrong.

| # | status | the "but" | why it matters | how to close it |
|---|---|---|---|---|
| **B1** | CLOSED | **1097 of 3470 entry points return zero and say nothing.** They forward to `glfwd_absent`. An application that links one gets a silent no-op, not a diagnostic | This is the difference between "works" and "works for the applications tried". A silent zero is the failure mode this repository spends the most words warning about, and the shim now has one by construction | Make the absent case observable without making it fatal: a one-line-per-name report at first call under `CROSS_LIBC_DLOPEN_DEBUG=1`, which needs the register-saving resolver stub described in B2. Then measure which of the 1097 a real application actually touches -- likely zero, and "likely" is the problem |
| **B2** | CLOSED | **The trampolines cannot report, because a table slot cannot run code.** The current design fills the table in a constructor and every slot is either a real address or a silent stub | It also forces the eager load in B4 and blocks per-symbol laziness | Write the x86-64 register-saving resolver: save `rdi rsi rdx rcx r8 r9 xmm0-7 rax`, call a C resolver with the index, restore, tail-jump. This is `_dl_runtime_resolve` minus the bookkeeping, ~60 lines, and it is the single change that unlocks B1 and B4 |
| **B3** | CLOSED | **Only ONE non-glvnd host family has been tested: musl Alpine.** The other half of the claim -- pre-glvnd **glibc** distros, Ubuntu 14.04/16.04, Debian 8 -- is asserted, not measured, here | The README and REPORT 9 both say "every musl distro, and every pre-glvnd glibc distro". Half of that sentence has evidence | `ubuntu:14.04` and `ubuntu:16.04` still exist on Docker Hub; their apt repositories moved to `old-releases.ubuntu.com`, which is a `sources.list` rewrite, not a blocker. Add them as a third and fourth host to `appimage.ps1` and run E59-E68 there. Mesa 10.1 is also the one stack where the `_glapi_tls_Dispatch` case in REPORT 9.5 might reproduce, which would close a second open question at the same time |
| **B4** | CLOSED | **The shims load the host GL stack in every process, GL or not.** Measured cost: +30 ms and +30 MB on a Vulkan-only run | Small, but it is 30 MB of host Mesa mapped into a process that will never call it, and the reason it is not gated is that the gate was judged too dangerous to write. With B2 done it becomes trivial: nothing resolves until something calls | Gate on first call, via B2's resolver. Delete the constructor's `dlopen` entirely |
| **B5** | CLOSED | **No GLES shim.** `libGLESv2.so.2` and `libGLESv1_CM.so.1` are the same shape and are not covered | An AppImage bundling Mesa's GLES has the identical gap and would fail identically. The generator and the shim already do everything needed; this is a table and two `-D` flags | `make gl-syms` against a bundled `libGLESv2.so.2`, add the build rule, add an E-case. Note the demo AppDir bundles neither, so this needs an AppDir that does -- see B6 |
| **B6** | CLOSED | **Two applications, one of which I wrote.** `glxgears` (33 GL symbols) and `glprobe` (15). Nothing real | 3470 forwarded entry points have been exercised at a rate of about 1%. The claim "it replaces libGL" rests on the export count, not on use | Build a demo AppDir around something with a real GL surface. `pkgforge-dev/Anylinux-AppImages` `useful-tools/demo/` has recipes for gtk3/gtk4/qt6/sdl/webkit2gtk AppImages; any of those on Alpine is a far harder test than `glxgears` |
| **B7** | ⛔ BLOCKED | **Never on real silicon on the non-glvnd path.** Every GL result on Alpine is llvmpipe under Xvfb | The d3d12 path (E53) proves hardware GL works through the AppImage on a **glvnd** host. The classic-Mesa path has no hardware result at all | Alpine has no `d3d12_dri.so` (E53a's skip reason). Either build Mesa's d3d12 Gallium driver for Alpine, or accept this as hardware-blocked and say so in one sentence instead of leaving it implied |
| **B8** | CLOSED | **aarch64 trampolines assemble and have never run.** `make gl-fwd-asm-check` produces correct instructions and relocations and proves nothing else | The repository already carries this caveat for `RS_LDSO` and `RS_TRIPLET`; `gl-fwd` adds hand-written assembly to it, which is a larger thing to be unverified | Hardware, or a qemu-user run under `--platform linux/arm64`. The second is cheap and worth trying before declaring it blocked |
| **B9** | CLOSED | **The shim guessed where the host keeps its libraries.** A hardcoded directory list had `<triplet>/mesa` and not `<triplet>/mesa-egl`, so EGL failed on every pre-glvnd Ubuntu while GL worked | Reported from outside, in a pull request from @Samueru-sama. Not a missing entry: a guess about somebody else's packaging, which had already drifted from the path sharun assembles | Derive the list from `/etc/ld.so.conf` instead, sharing one walk with `runtime-select.c`. See 4.0.1 |

⭐ **B2 is the keystone.** B1 and B4 both reduce to it, and it is the one piece
of genuinely new machinery. B3 is the highest-value item that needs no new
machinery at all.

⛔ **Do not start the port until B1, B2, B3 and B6 are closed.**
`PORTING.md` is written and waiting, and it is deliberately a
separate session with a separate agent. Porting a claim that is wider than its
evidence just publishes the gap.

> *That port has since happened, and `PORTING.md` was consumed by it: the file
> named above no longer exists. Everything it asked for is either in the tree
> or is an entry in [`TODO/`](../TODO/INDEX.md).*

### 4.0.1 Closure records

One entry per item that has closed, with the command that proves it and the
output it produced. ⛔ Where a premise in the row above turned out to be wrong,
the correction is here and the row keeps its wording, because the row is how
the item has been referred to everywhere else.

#### B2 -- the resolver exists, and it is measured

`src/gl-fwd.c`. Every slot now starts at `glfwd_resolve_asm` instead of at an
address, and each trampoline carries its own index in a register the ABI
already lets a call destroy -- `%r11` on x86-64, `x17`/IP1 on aarch64:

```asm
glClearColor:
	endbr64
	mov    $0xc1, %r11d            # 193, and glfwd_tab+0x608 is 8*193
	jmp    *0x296b8(%rip)
```

The resolver saves `rax rdi rsi rdx rcx r8 r9 r10 xmm0-7`, calls
`glfwd_resolve_one(index)`, restores and tail-jumps. `and $-16,%rsp` makes the
alignment unconditional rather than argued, because a trampoline is reached
from anywhere and the `movaps` faults on a misaligned address.

Measured by **E69-E73** in `experiments/run.ps1`, section N, against the real
`src/gl-fwd.c` built with a five-name table -- not a copy of the resolver that
could drift from it:

```
E69  OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12]
         second-call-identical=yes absent-returned=0
```

Eight integer registers, nine float registers, a varargs `%al` count and a
struct returned through hidden memory, all surviving a C call made in the
middle of the forward -- and the second call agreeing with the first, which is
what says the slot was patched with the right address rather than that the
resolver got lucky once.

#### B4 -- nothing loads until something calls

The constructor's `dlopen` is gone; `glfwd_ensure_target()` runs at the first
call through any slot. `CROSS_LIBC_DLOPEN_GL_EAGER=1` restores the old behaviour,
so the cost of not doing it stays a measurement rather than a memory.

Asked of `/proc/self/maps`, because "it started faster" is not evidence about
what was loaded, and asked on **both** sides -- E71 alone would also pass if
the shim were simply broken:

```
E71   OK: shim mapped=1 target mapped=0 (called=-1)     no call
E71b  OK: shim mapped=1 target mapped=1 (called=204)    one call
```

and at AppImage scale, on both host classes, in `appimage.ps1`:

```
E74   Vulkan-only run: 2 shim(s) loaded, 0 resolved, no host GL mapped
E74b  the same shims, after a GL call: 2373 of 3470 entry points resolved
```

⚠ **The row's "+30 ms and +30 MB" is now the cost of `CROSS_LIBC_DLOPEN_GL_EAGER=1`
and not of the default**, and that is measured rather than inferred:

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

REPORT.md 9.9 has the same table beside the `/proc/self/maps` measurement,
because a clock says how long and only the maps say what loaded.

#### B1 -- and the answer to the question the row could not ask

The absent case is now a line at the first call of that name, under
`CROSS_LIBC_DLOPEN_DEBUG=1`, and not fatal -- returning zero is what the application
would get natively on a host where the name is equally absent:

```
E72   [gl-fwd.so] >> ABSENT entry point called: t_absent -- this host's
                     libtgt.so has no implementation; returning zero
```

The row asked for something the old design could not measure at all: *which of
the 1097 does a real application actually touch -- likely zero, and "likely" is
the problem.* On alpine:3.22, `glprobe` through the full AppDir:

```
libGL.so.1: 2373 of 3470 entry points resolved from the host library
            (1357 exported, 1016 via glXGetProcAddressARB, 1097 absent)
libGL.so.1: 15 of 3470 entry points were CALLED (15 forwarded, 0 absent)
            out of 2373 this host could resolve
absent entry points this application reached: 0
```

**Zero, measured.** ⭐ And the second line is the number B6 has been guessing
at: `glprobe` touches **15 of 3470**, which is 0.4%, not the "about 1%" B6's
row estimates. That number is reported and never thresholded -- it is a
property of the application, and a bar here would be a bar on somebody else's
program.

#### B3 -- the other host class, measured, and one premise corrected

⚠ **The row's route is wrong and would have stopped you.** It says these
images' repositories "moved to `old-releases.ubuntu.com`, which is a
`sources.list` rewrite, not a blocker". As of 2026-08 `old-releases` does not
carry `trusty` or `xenial` **at all** -- its `dists/` listing jumps from
`saucy` to `utopic` and every path 404s. Both releases are still inside their
ESM window and are still served from **`archive.ubuntu.com` at the default
path**, so the prescribed rewrite is the thing that breaks them. What does have
to go is the image's own ESM source: it points at `esm.ubuntu.com`, needs
credentials, and apt fails the whole update over it and then reports every
package as "unable to locate", which reads exactly like a dead mirror.

```sh
rm -f /etc/apt/sources.list.d/*esm*      # and leave sources.list alone
```

`experiments/46-host-ubuntu.sh` is the third and fourth host; `appimage.ps1`
runs all four by default and `-Only ubuntu1404` runs one.

```
ubuntu:14.04   glibc 2.19   Mesa 10.1.3   26/26, 19 named skips
ubuntu:16.04   glibc 2.23   Mesa 18.0.5   26/26, 19 named skips
```

Both are classic: no `libGLX_<vendor>.so.0` anywhere. On 14.04 `glxgears`
renders (`Gallium 0.4 on llvmpipe (LLVM 3.4)`), `glprobe` reads its pixel back,
and `eglprobe` gets a context. **The pre-glvnd glibc half of the claim has
evidence now.**

⭐ **And the resolution counts match an independent run on hardware nobody here
has.** @Samueru-sama
reported Ubuntu 14.04 from a seven-distro matrix on a real RX 580:

```
reported : libGL.so.1: 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
measured : libGL.so.1: 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
```

Same numbers, different hardware, different display path, different Mesa point
release. That is a prediction that held.

**Two things the row hoped for did not happen, and one it did not expect did.**
The `_glapi_tls_Dispatch` case in REPORT 9.5 did **not** reproduce on Mesa
10.1: GL works there, and nothing needed the global scope to do it. What
happened instead is on 16.04, and it is worth more -- see B3's second finding
below.

#### B3's second finding: the `ld.so.cache` blindness, fourth sighting

Ubuntu 16.04 failed three cases, and the failure was not the shim. Its host
`libGL.so.1` loads, the shim resolves 2354 of 3470 entry points from it, and
then Mesa `dlopen`s its own `swrast_dri.so`, which needs `libLLVM-6.0.so.1` --
reachable on that host **only** through `/etc/ld.so.cache`, which the bundled
`ld.so` is patched not to read (E13b). What the user sees:

```
libGL error: unable to load driver: swrast_dri.so
X Error of failed request:  BadValue
  Major opcode of failed request:  151 (GLX)
  Minor opcode of failed request:  3 (X_GLXCreateContext)
```

A display fault, apparently. It is the same bug as `CUDA_ERROR_NO_DEVICE`
(E44) and `glXCreateContext failed` (E53a). **E77** now measures it on every
host, and what it scores is the DIAGNOSTIC rather than the outcome -- the
outcome is a property of how a host packages its driver, but "when this bites,
the process names the library it could not find" is true everywhere.

#### B3's third finding: predict what the HOST does, not what you hoped

`eglprobe` failed on 16.04 with the shims. So it does **natively**, with no
AppImage, no preload and no shim in the process:

```
native eglprobe on ubuntu:16.04    EGL_VERSION : 1.4   EGL_VENDOR : Mesa Project
                                   readback rgba : 0 0 0 255 (want ~64 128 191 255)
                                   FAILED: the pixel does not carry the colour that was set
```

Mesa 18.0.5 does not produce that pixel on that host at all. A shim that then
produced it would be inventing one. ⛔ So **E78 and E79 build and run the
probes natively and E64/E66 are predicted against THAT**, not against a
constant: the shim's claim is transparency, so the yardstick is the host. This
also corrects a hypothesis offered in the issue -- that 16.04's readback fails
because the GL and EGL shims do not share dispatch state. There are no shims in
the native run.

#### B5 -- the GLES dispatcher, from an AppDir that has one

`src/gl-fwd-gles2.h`, **358 entry points**, read out of the `libGLESv2.so.2`
bundled by the gtk4 demo AppImage; `make gles-syms GLES=<dir>` regenerates and
`make gles-syms-check` fails on drift. The row is right that it is "a table and
two `-D` flags" -- and right that it needed an AppDir that bundles GLES, which
is why it waited for B6.

GLES finds its implementation the way EGL does, through
`/usr/share/glvnd/egl_vendor.d`, so `gles-fwd.so` is the same source file with
EGL's vendor marker and its own table.

⭐ It is not a completeness exercise. **GTK4 renders through GLES**: E83
measures gtk4-demo calling 46 distinct GLES entry points, 13 EGL and 1 GL. On a
classic host without this shim, those 358 names are 358 silent zeros.

`libGLESv1_CM.so.1` is **not** done, and not because it is hard: no AppImage
available here bundles one, and the generator's rule is that the list comes out
of the object being replaced. One `make gles-syms` against an AppDir that has
one is the whole job.

#### B6 -- a real application, and it found a bug

`experiments/47-gtk4.sh`, a fifth stage: the gtk4-demo AppImage -- 272
libraries, its own Mesa, its own `libEGL_mesa.so.0`, a real GTK4 application --
on musl Alpine. This is the other SHAPE of AppImage, self-contained rather than
host-drivers, and four synthetic cases and two host classes had never seen one.

**It failed, and the shim was wrong.** `glfwd_host_has_vendor()` asked only
whether the HOST had a vendor library. On Alpine it does not, so the shim
forwarded a bundled GTK4 stack onto Alpine's Mesa: two Mesas in one process,
`SIGFPE`. The same AppImage with no shim in `.preload` ran fine, which is what
made it a shim bug and not a host one.

The repair is `glfwd_bundle_has_vendor()`: if the BUNDLE carries its own vendor
library, the bundled dispatcher is what the application was built and tested
against and the shim leaves it alone. That is also what makes this shim safe to
put in *every* AppImage's `.preload` rather than only in the host-drivers ones.

```
E80a  as shipped, no shims          rc=143  (still running when the timeout ended)
E80   gl + egl + gles shims         rc=143  (was 136/SIGFPE)
E81   target chosen                 the bundled dispatcher, because the BUNDLE
                                    has its own vendor library
E82gl/egl/gles   3470 of 3470, 44 of 44, 358 of 358 entry points resolved
E83   gtk4-demo called 1 GL, 13 EGL and 46 GLES entry points
```

⭐ **E83 is the number the row is about.** "3470 forwarded entry points
exercised at about 1%" was an estimate; the measured figures are `glprobe` at
15 of 3470 (0.4%) and gtk4-demo at 46 GLES of 358 (13%) -- and the useful part
is not the percentage, it is that **the application's renderer was GLES**, a
dispatcher this repository did not cover until this AppDir arrived.

#### B7 ⛔ -- hardware-blocked here, and the reason is structural

The row asks for one sentence rather than an implication, so: **there is no
host on this machine that is both classic-Mesa and able to reach a GPU, and
that is not an accident of what is installed.** Measured, not assumed:

```
alpine:3.22  /usr/lib/dri: crocus i915 iris kms_swrast libdril nouveau r300
             r600 radeonsi swrast virtio_gpu vmwgfx zink -- no d3d12_dri.so
/usr/lib/wsl/lib: libcuda, libnvidia-*, libd3d12.so, libdxcore.so
             -- no libGL, no libGLX_nvidia.so.0, no libEGL
```

The only GPU route here is Mesa's `d3d12` Gallium driver over `/dev/dxg`, which
needs Mesa ≥ 21. Every glibc distro shipping Mesa ≥ 21 uses libglvnd, and the
classic-Mesa holdouts are the musl distros, which do not build `d3d12`. The two
properties are anti-correlated, so this is not "wait for a package".

⭐ **It has been measured elsewhere, and that is recorded as elsewhere.**
@Samueru-sama reports
`glprobe` passing on Alpine 3.21 with hardware `radeonsi` on an RX 580 -- GL on
real silicon on the classic path. Not reproduced here, not adopted as if it
were, and named the same way REPORT 9.5 names the Mesa 10.1 report it also
could not reproduce.

#### B8 -- the aarch64 trampolines have now run

`make gl-fwd-qemu-check`, and **E76/E76b** in `run.ps1` section P. qemu-user
runs an aarch64 binary on an x86_64 kernel in userspace, and everything under
test is userspace: the trampoline, the resolver, ld.so binding a `DT_NEEDED` to
a preloaded object with the same SONAME, and `dlopen`.

```
t_ints:
    bti  c
    mov  w17, #0x0
    adrp x16, glfwd_tab
    ldr  x16, [x16, #272]
    br   x16

E76   OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12]
      second-call-identical=yes absent-returned=0
E76b  ABSENT entry point called: t_absent
```

⚠ **Not the row's route.** `podman run --platform linux/arm64` replaces the
cached image for that tag, and one probe left `alpine:3.22` resolving to arm64
and killed the next suite run with `Exec format error`. Naming
`qemu-aarch64-static` needs no binfmt registration -- a kernel-wide setting --
and no privilege.

Still UNVERIFIED: aarch64 **silicon**. qemu-user emulates the instructions, not
a real memory model or a real Mesa.

#### B9 -- a new item, from outside: the shim stops guessing where libraries are

Not in the original eight. A pull request from @Samueru-sama
reported that `egl-fwd.so` cannot find the host's classic `libEGL.so.1` on
Ubuntu's alternatives layout: `glfwd_host_dirs[]` listed `<triplet>/mesa`,
where classic `libGL` lives, and not `<triplet>/mesa-egl`, where classic
`libEGL` lives. EGL therefore failed on every pre-glvnd Ubuntu while GL worked.

The PR's own follow-up made the better argument: a hardcoded list of somebody
else's packaging conventions is a guess, it had already drifted from the path
sharun assembles, and adding an entry treats the symptom. Section 7 says the
same thing -- gl-fwd's list is "the one deliberate exception, and it is
bounded... it must not grow into one".

So the list is now **derived**. [`src/ld-conf.h`](../src/ld-conf.h) is one walk of
`/etc/ld.so.conf`, shared by `gl-fwd.c` and `runtime-select.c` so there is one
parser rather than two, and the shim looks in this order:

1. `CROSS_LIBC_DLOPEN_GL_HOST_DIR` -- the explicit handoff a launcher can use
2. every directory `/etc/ld.so.conf` and its includes name -- **the host's own
   answer**, which on Ubuntu is `x86_64-linux-gnu_EGL.conf` naming `mesa-egl`
3. the conventional list, which now includes PR #4's `mesa-egl` entries --
   still needed, and not in name only: musl distros have no `/etc/ld.so.conf`
   at all, so on the very host class this shim exists for, list 3 is the only
   one that answers

**E75/E75b** measure it on a directory no list could contain, so a pass cannot
come from the hardcoded entries, and the control is the conf file's absence
rather than a switch invented to disable the feature:

```
E75   target /opt/cross-libc-unguessable-42/libtgt.so     conf file present
E75b  no target; all 5 entry points return zero          conf file removed
```

### 4.1 The blocker, now fixed

`vkEnumeratePhysicalDevices` returned `VK_ERROR_OUT_OF_HOST_MEMORY` with zero
devices. This was attributed to glibc-vs-musl ABI differences. **It was not
that.**

The measurement that broke it open was reproducing the failure on
`debian:trixie-slim` with **one libc**: Debian's own glibc-built
`libvulkan_lvp.so`, glibc 2.41 on both sides, no musl anywhere. Then the chain
fell out in an afternoon, because Debian ships Mesa's `__FILE__` strings and
`mesa-vulkan-drivers-dbgsym` exists:

```
lvp_device.c:1315            lvp_init_wsi() failed
wsi_display_init_wsi()       -> VK_ERROR_OUT_OF_HOST_MEMORY
wsi_common_display.c:2323    u_cnd_monotonic_init() -> thrd_error
                             pthread_cond_init() -> 22 (EINVAL)
gdb, info symbol $pc         libc+0x909f0 = pthread_cond_init@GLIBC_2.2.5
                             (the working run: libc+0x91b00 = @@GLIBC_2.3.2)
```

`pthread_cond_init@GLIBC_2.2.5` is the pre-2003 compat definition and its whole
body is `if (cond_attr != NULL) return EINVAL;`.

**An unversioned reference does not get the default definition of a symbol.**
A version-stripped object has only unversioned references. So does every
musl-built object, which never had version information at all. That is why the
same failure showed up on Alpine, on Gentoo with a glibc `radv`, and on Debian
once the ICD manifest named an absolute path.

The fix is [`src/version-compat.c`](../src/version-compat.c) plus
[`tools/version_traps.py`](../tools/version_traps.py); REPORT.md 6.2 has the whole
chain with the commands.
