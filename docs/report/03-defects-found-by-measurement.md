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
them loaded yet, so the precise version of the question would have answered
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
libc could own: not `_Z`-mangled, not `LLVM*`. **E28**.

### 3.6 The failure report was itself destructive

Found while testing 3.5, and the same class of bug as 3.3 reached from the other
side. `cld_report_unresolved()` probes with `dlsym`, and **every probe that
misses replaces the pending `dlerror()` message**. The caller, about to ask for
it, was handed

```
/work/cross-libc-dlopen.so: undefined symbol: _ZN4llvm9Attribute16getWithAlignmentEv
```

(this object blamed for a failure in a different one) instead of ld.so's
actual `libvendor.so.1: cannot open shared object file`. The code carries a
comment saying it makes no `dlerror()` call, which was true and not enough.

**Fix:** re-run the load after the report, which puts the real message back.
One extra failed `dlopen`, only in a trace run. **E29**.

---

---

[REPORT index](README.md) | [previous](02-environment.md) | [next](04-design-r-runtime-selection.md)
