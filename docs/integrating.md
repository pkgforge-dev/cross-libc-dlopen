# Integrating it

The interface is **`LD_PRELOAD`** (or `ld.so --preload`). Everything else is one
consumer's way of populating it.

---

## The one requirement

⛔ **This object's `dlopen` pass-throughs must run AFTER any other `dlopen`
interposer in the process.** That is the requirement. It is not advice about a
particular launcher.

⚠ And it is *not* the same as "list it last". Preload **constructors run in
REVERSE of the list** (measured in E56 and E57), so listing this object last runs
its constructor *first*. Rather than depend on a loader ordering nobody
documents, the GL shims **ask**: they `dlsym` for
`cross_libc_dlopen_init_now` and call it if it is there.

Since the loader went lazy this handshake is belt-and-braces rather than
load-bearing, because by the first GL call every constructor has long since
run ([`REPORT.md`](REPORT.md) section 9.6). It costs nothing and it removes an
ordering question from every integration.

---

## Turning it on

⭐ **Nothing.** It is on whenever the object is preloaded, because preloading
it is already the deliberate act. There is no marker file to create and no
variable to remember.

```bash
CROSS_LIBC_DLOPEN=0
```

turns it off, and that is the only thing the variable is for now. `=1` still
works and still forces it on.

⚠ **This changed.** It used to need `CROSS_LIBC_DLOPEN=1` or a
`.cross-libc-dlopen-enabled` marker at the root, and a consumer that preloaded
the object and set neither got a run that did nothing and gave no hint why. The
markers are gone. E89 and E90 in `experiments/30-run-tests.sh` measure both
sides: on by default, and still switchable off.

## Telling it where the bundle is

```bash
CROSS_LIBC_DLOPEN_ROOT=/path/to/bundle     # this project's name
APPDIR=/path/to/bundle                     # the AppImage runtime sets this itself
CROSS_LIBC_DLOPEN_LIBDIR=lib               # default; the directory under the root
```

⛔ **`APPDIR` is not a deprecated alias.** It is a convention this project does
not own: an AppImage runtime exports it into every process it starts, before
anything here runs. `CROSS_LIBC_DLOPEN_ROOT` wins when both are set.

⭐ **If you want one spelling and no interop, take the `portable` build.**
Every release ships it beside the default, as
`cross-libc-dlopen-portable-<arch>.tar` and `.zip`. Those objects read
`CROSS_LIBC_DLOPEN_ROOT` and never look at `APPDIR`; the string is not even in
the binary. To build it yourself:

```bash
sh scripts/build.sh --portable
```

⛔ **Every control has exactly one name.** The `ANYLINUX_*` spellings this
project used before it was renamed are no longer read by anything in `src/`.
Nothing consumed them: there has never been a published release, so no bundle
sets one. E84 and E85 in `experiments/30-run-tests.sh` are the pair that keeps
that true. See [`src/cld-env.h`](../src/cld-env.h).

⚠ `APPDIR` above is not one of those. It is a consumer's spelling of the bundle
root and it stays accepted.

---

## Per target

### An AppImage laid out by `quick-sharun`

The hardest consumer, because it supplies its own loader. It is also the one
every measured result in [`REPORT.md`](REPORT.md) was obtained through.

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

⚠ **That list is for a bundle you are building.** An older bundle names
`foreign-dlopen.so` in its `.preload` instead. To retrofit one, copy the built
`cross-libc-dlopen.so` **over whichever name that bundle's `.preload` already
carries**, rather than adding a second entry.

⛔ **Do not assume the name, and do not hardcode either spelling.** Upstream has
changed it once: the demo AppImage this repository's suite pins shipped
`lib/foreign-dlopen.so` and now ships `lib/cross-libc-dlopen.so`. Read the
bundle's own `.preload` and use what is in it, which is what
`experiments/41-extract.sh` does before `experiments/40-appimage.sh` touches
anything. [`REPORT.md`](REPORT.md) 9.17.

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
