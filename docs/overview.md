# Two gaps, and the failure message each one gives you

A bundle that ships its own glibc cannot ship GPU drivers -- Mesa plus LLVM is
100-200 MB -- so it has to use the host's. Two different things stop it, and
telling them apart is the whole idea.

Getting the diagnosis backwards costs a session, because the second gap's error
message is about neither of its two subjects.

---

## Gap 1: libc

**The host's driver exists, is nameable, and was built against a different
libc** -- a newer glibc, or musl. A process carrying a bundled glibc 2.31
cannot `dlopen` an object that wants `GLIBC_2.38`, and cannot `dlopen` a musl
object at all.

What you see:

```
libfoo.so.1: version `GLIBC_2.38' not found (required by /usr/lib/libbar.so.0)
```

```
libc.musl-x86_64.so.1: cannot open shared object file: No such file or directory
```

Both name the thing that is wrong. This gap is the polite one.

**The repair** is [`src/cross-libc-dlopen.c`](../src/cross-libc-dlopen.c): an
`LD_PRELOAD`ed `dlopen` interposer that rewrites the host object in a private
copy so its symbol version requirements stop mattering, drops the musl libc
dependency edge, and bridges the imports that are left.

Three files support it:

| file | what it does |
|---|---|
| [`src/forward-shim.c`](../src/forward-shim.c) | **generated.** Supplies what the bundled libc lacks. Regenerate with `make shim`; never hand-edit |
| [`src/version-compat.c`](../src/version-compat.c) | fixes a trap where an *unversioned* reference binds glibc's **obsolete** definition of a symbol rather than its default one |
| [`src/runtime-select.c`](../src/runtime-select.c) | can switch the whole libc runtime at `execve` time when the host's is newer |

---

## Gap 2: interface

**The host has the capability and ships nothing in the shape the bundled loader
looks for.** The bundle ships libglvnd; the application links `libGL.so.1`;
behind it `libGLX.so.0` `dlopen`s a vendor library called
`libGLX_<vendor>.so.0` -- and a host whose Mesa was built *without* glvnd ships
no such file at all.

⭐ **This is the single most useful sentence here.** What you see is:

```
couldn't get an RGB, Double-buffered visual
```

That is a message about **visuals**, for a fault that is about neither visuals
nor libc. No amount of libc bridging carries a file that does not exist. If you
are reading that line and reaching for the loader, you are on the wrong rung --
see [`diagnostics.md`](diagnostics.md).

**The repair** is [`src/gl-fwd.c`](../src/gl-fwd.c): an object built with the
SONAME of the library it replaces, preloaded so `ld.so` binds the application's
`DT_NEEDED` to it, forwarding every entry point of the bundled dispatcher to
whichever target the host can actually stand behind.

The same source file, built with three different tables, is three shims:

| built as | SONAME | table | entry points |
|---|---|---|---|
| `gl-fwd.so` | `libGL.so.1` | `gl-fwd-gl.h` | see [`REPORT.md`](REPORT.md) §9 |
| `egl-fwd.so` | `libEGL.so.1` | `gl-fwd-egl.h` | " |
| `gles-fwd.so` | `libGLESv2.so.2` | `gl-fwd-gles2.h` | " |

⭐ **One fact, one home.** Every entry-point count and every suite total lives
in [`REPORT.md`](REPORT.md) and is pointed at from everywhere else. A number
that appears in two documents disagrees with itself within a month, and the
reader has no way to tell which one is stale.

---

## Telling them apart, in one command

Gap 1 leaves a trail in the loader's own debug output; gap 2 leaves none,
because nothing was ever asked to load:

```bash
CROSS_LIBC_DLOPEN=1 CROSS_LIBC_DLOPEN_DEBUG=1 your-app 2>&1 | grep 'cross-libc-dlopen:'
```

Lines naming objects being rewritten mean gap 1 is being handled. **Silence,
with a rendering failure, means gap 2** -- the application never got as far as
asking for a host object, because the dispatcher it linked found no vendor to
dispatch to.

[`diagnostics.md`](diagnostics.md) is the full ladder.
