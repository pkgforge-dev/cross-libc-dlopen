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

---

[REPORT index](README.md) | [previous](03-defects-found-by-measurement.md) | [next](05-design-b-generated-shim.md)
