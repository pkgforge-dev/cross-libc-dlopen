# Integrating it

The interface is **`LD_PRELOAD`** (or `ld.so --preload`). Everything else is one
consumer's way of populating it.

---

## The one requirement

⛔ **This object's `dlopen` pass-throughs must run AFTER any other `dlopen`
interposer in the process.** That is the requirement. It is not advice about a
particular launcher.

⚠ And it is *not* the same as "list it last". Preload **constructors run in
REVERSE of the list** (measured -- E56, E57), so listing this object last runs
its constructor *first*. Rather than depend on a loader ordering nobody
documents, the GL shims **ask**: they `dlsym` for
`cross_libc_dlopen_init_now` and call it if it is there.

Since the loader went lazy this handshake is belt-and-braces rather than
load-bearing -- by the first GL call every constructor has long since run
([`REPORT.md`](REPORT.md) §9.6) -- but it costs nothing and it removes an
ordering question from every integration.

---

## Turning it on

Either of these is sufficient. **A consumer with no marker file does not have to
create one.**

```bash
CROSS_LIBC_DLOPEN=1
```

or drop a `.cross-libc-dlopen-enabled` marker in the root. The old spelling
`.foreign-dlopen-enabled` is still honoured, because that is the name
`quick-sharun` writes and bundles built before the rename carry it.

## Telling it where the bundle is

```bash
CROSS_LIBC_DLOPEN_ROOT=/path/to/bundle     # neutral
APPDIR=/path/to/bundle                     # one consumer's spelling, still accepted
CROSS_LIBC_DLOPEN_LIBDIR=lib               # default; the directory under the root
```

⚠ **The old `ANYLINUX_*` variable names are all still read**, as deprecated
aliases, for exactly one reason: a bundle built before the rename sets them from
its own launcher, and dropping them would make this object load and do nothing --
silently, because "the feature was off" and "the feature was never asked for"
produce an identical run. See [`src/cld-env.h`](../src/cld-env.h).

---

## Per target

### An AppImage laid out by `quick-sharun`

The hardest consumer, because it supplies its own loader -- and the one every
measured result in [`REPORT.md`](REPORT.md) was obtained through.

Add the artefacts to the AppDir's `lib/` and name them in `.preload`:

```
path-mapping.so
anylinux.so
cross-libc-dlopen.so
gl-fwd.so
egl-fwd.so
gles-fwd.so
```

⚠ `.preload` is **sharun's** file, not this project's. Its ordering does not
matter, for the reason above.

⚠ **That list is for a bundle you are building.** A bundle built *before* this
rename already names `foreign-dlopen.so` in its `.preload`, and `quick-sharun`
still writes that name. To retrofit one, copy the built
`cross-libc-dlopen.so` **over** `lib/foreign-dlopen.so` rather than adding a
second entry -- which is exactly what `experiments/40-appimage.sh` does, and
why that path is spelled upstream's way throughout the harness.

⚠ **`SHARUN_FALLBACK_LIBRARY_PATH` is how the harness talks to THIS launcher**,
not an interface of this project. It extends the library path sharun assembles,
and it matters because the loader here **can only reach a host driver that
sharun's `--library-path` already reaches**. A driver whose directory is named
only in `/etc/ld.so.cache` is invisible without it.

⛔ **A bundle that ships its own vendor library must KEEP it.** Forwarding to
the host's because the host has none puts two Mesas in one process. The default
target is the bundled dispatcher whenever the bundle *or* the host has a vendor
library for it, and the host's own library only otherwise; `examples/` shows the
failure this rule exists to prevent.

### A plain binary, no bundle anywhere

```bash
LD_PRELOAD=/path/to/cross-libc-dlopen.so \
CROSS_LIBC_DLOPEN=1 \
  ./your-program
```

No `APPDIR`, no marker, no `.preload`. See
[`examples/plain-preload/`](../examples/plain-preload/) for a run with a before
and an after.

### A self-contained-executable packer (`onelf` and friends)

These solve the *other* half of the same problem: they bundle the entire libc
and bootstrap so the host loader is never consulted. The wall they hit next is
that the host's `libdrm`, `libgcc_s` and so on are the wrong family. That wall
is what this removes. See [`examples/README.md`](../examples/README.md).

### Static binaries

⚠ **"Static binaries cannot `dlopen`" is the wrong answer.** It is close enough
to true to be repeated and wrong in the way that matters. Three distinct cases,
and [`limits.md`](limits.md) says which of them has been measured here and
which has not.
