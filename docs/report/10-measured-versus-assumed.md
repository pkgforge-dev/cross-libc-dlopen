## 10. Measured versus assumed

**Measured:** every table and quoted output above, plus `sh scripts/run-evidence.sh`
(53/53 on x86-64, 50/50 on aarch64), `sh scripts/run-appimage.sh` (45/45 glvnd glibc, 40/40 musl with five
named skips, 26/26 on each pre-glvnd glibc host, 7/7 on the gtk4 stage), `tools/gap.py --fetch`, the eight-distro inventory, the AppImage inventory,
the corpus test, and the five-distro `ld.so.cache` survey in
`../ground-truth.md`.

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
  case the GLES shim was written for, a classic host with no EGL vendor, is
  covered by construction and by the GL and EGL cases that share its code path,
  not by a measurement of its own.
- **The aarch64 trampolines RUN, under qemu-user, and have never touched
  aarch64 silicon.** This entry used to say "assembled, never run", which is a
  weaker claim, and `make gl-fwd-qemu-check` plus E76/E76b replaced it: qemu
  executes an aarch64 binary on an x86_64 kernel in userspace, and everything
  under test is userspace: the trampoline, the register-saving resolver,
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
  that DOES reach one. None of the four measured here does, so the
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

---

[REPORT index](README.md) | [previous](09-the-second-boundary.md) | [next](11-known-unfixed.md)
