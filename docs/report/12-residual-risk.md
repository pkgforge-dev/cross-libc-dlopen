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
   a musl-built object reading a glibc-filled struct back at its own stride,
   because `regoff_t` is 4 bytes on glibc and 8 on musl, and comparing against its own
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
   because glibc lets an unversioned definition satisfy a versioned reference,
   which is how `LD_PRELOAD` interposition has always worked. It then forwards to
   the same default definition it would have reached directly, so behaviour is
   unchanged and the cost is one indirect call. The case this would get wrong is
   an object that genuinely wants an obsolete version: glibc 2.2.5-era condition
   variables, 2003 or earlier. Nothing that ships in an AppImage does, and
   nothing was found that does, but this is an assumption rather than a
   measurement.
8. **Library discovery, not `dlopen`, is what breaks a host driver most often
   here, and two of the three assemblers are still hardcoded lists.**
   `src/runtime-select.c` now derives its directories from `/etc/ld.so.conf`
   (section 7.3). Sharun does not yet, and the patch exists and is unapplied.
   `cross-libc-dlopen.c` deliberately never will, because finding libraries is
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
   work introduced, and it is not fixed here. It is recorded because "it
   worked with the feature off" is not the reassurance it looks like.

---

[REPORT index](README.md) | [previous](11-known-unfixed.md)
