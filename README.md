# cross-libc `dlopen`

An application that bundles its own glibc can run anywhere, but it cannot
bundle GPU drivers. Mesa plus LLVM is 100 to 200 MB, so the drivers have to
come from the host. Two things can stop that, and they fail differently.

## The two problems

**1. The host's driver was built against a different libc.**

The bundled application ships one glibc. The host's driver may want a newer
glibc, or it may be linked against musl entirely. Neither can load into the
bundled process.

```
version 'GLIBC_2.38' not found (required by /usr/lib/.../libfoo.so)
libc.musl-x86_64.so.1: cannot open shared object file
```

This is fixed by `cross-libc-dlopen.so`, an `LD_PRELOAD`ed `dlopen`
interposer. It rewrites the host object in a private copy so symbol version
requirements stop mattering.

**2. The host has the capability, but ships nothing in the shape the bundled
loader looks for.**

The bundle ships libglvnd. A host whose Mesa was built without glvnd has no
`libGLX_<vendor>.so.0` for it to `dlopen`, and the error you get has nothing to
do with libc or visuals:

```
couldn't get an RGB, Double-buffered visual
```

This is fixed by `gl-fwd.so`, `egl-fwd.so` and `gles-fwd.so`. Each is built
with the SONAME of the library it replaces, so `ld.so` binds the
application's `DT_NEEDED` to it and forwards every entry point to whatever
the host can stand behind.

⭐ **This is a preload, not an AppImage feature.** It needs a dynamically
linked process whose libc differs from the driver's. An AppImage is the
hardest such consumer, because it supplies its own loader as well as its own
libc, so it is what every measured result here was obtained through. Nothing
in the mechanism requires one: [`examples/plain-preload/`](examples/plain-preload/)
runs it against an ordinary binary with no AppDir anywhere.

---

## Quick start

```bash
sh scripts/build.sh
```

This detects `podman`, `docker` or a native toolchain, reports what it found,
and writes every artefact plus a manifest under `build/`. Then, for any
dynamically linked program:

```bash
LD_PRELOAD=/path/to/cross-libc-dlopen.so ./your-program
```

There is nothing to switch on. Preloading it is the opt-in, and
`CROSS_LIBC_DLOPEN=0` is how you switch it back off.

For a bundle, put `cross-libc-dlopen.so`, `gl-fwd.so`, `egl-fwd.so` and
`gles-fwd.so` in the bundle's `lib/` and name them in `.preload`.
[`docs/integrating.md`](docs/integrating.md) has the detail per target.

Packaging it? `cd src && make portable` needs no container and no script, and
is what `scripts/build.sh --portable` runs.

`scripts/build.sh` builds in a container on glibc 2.31 by default, so the
artefacts load into any bundle. The one way to get this wrong is a native
build on a newer glibc, and the script refuses that by name.
[`docs/building.md`](docs/building.md) has the measurement.

---

## Where it has been tested

The library has been tested on a wide range of systems and it works on all of
them, including:

- Ubuntu 12.04 through 22.04
- Alpine Linux
- Arch Linux
- Artix Linux
- NixOS
- Slackware

The measured record, every host and every count, lives in
[`docs/report/README.md`](docs/report/README.md) and nowhere else.
[`docs/reproducing.md`](docs/reproducing.md) is how to re-run every number
yourself.

⚠ What is **not** measured is [`docs/limits.md`](docs/limits.md), and it is a
list rather than a silence.

---

## Known limitations

The preload bridges the libc and the dispatcher. It cannot give a host a GPU
feature the host's own driver does not provide, and these are the places where
that shows up.

| what needs it | the catch |
|---|---|
| **GTK4 applications** | needs an **OpenGL 3.2** host context, and works wherever one exists: Ubuntu 16.04, softpipe (GL 3.3), Mesa 26.1.4. The one failure seen is Ubuntu 14.04's Mesa 10.1, which cannot create any GL context behind a modern glvnd dispatcher; there GTK4 still runs, but falls back to Cairo and GL-using widgets report "GL disabled". The preload cannot manufacture a context the host's Mesa will not create. Measured, recorded in [`docs/limits.md`](docs/limits.md) |
| **Applications that need OpenGL 4.6** | Mesa only reached OpenGL 4.6 in release 20.0 (February 2020), on radeonsi. A system whose Mesa predates that stops at OpenGL 4.5, so an application that demands 4.6 will not get it. In Ubuntu terms that means 20.04 and later are fine; 18.04 and earlier are not. The Mesa release notes for [20.0.0](https://docs.mesa3d.org/relnotes/20.0.0.html) state it: OpenGL 4.5 in 19.x, 4.6 from 20.0 |
| **Applications that need Vulkan 1.3 or newer** | Mesa shipped Vulkan 1.1 and 1.2 for years and only reached 1.3 in release 22.0 (March 2022), on RADV and ANV. An application that requires Vulkan 1.3 (or the newer 1.4) will not find it on a distribution whose Mesa predates that, no matter how the libc gap is bridged. The [22.0.0 release notes](https://docs.mesa3d.org/relnotes/22.0.0.html) say so |

⭐ **The pattern behind all three:** the host's Mesa is the ceiling. This
project lets a bundled application *reach* that ceiling across a libc boundary;
it does not raise the ceiling. What a driver cannot do stays undone, and
[`docs/limits.md`](docs/limits.md) is the full, measured list.

---

## Reproducing it

```bash
sh scripts/run-evidence.sh
```

The fast gate, about four minutes.

```bash
sh scripts/run-appimage.sh
```

The end to end proof, tens of minutes. Both need `podman` or `docker` and
nothing else. [`docs/reproducing.md`](docs/reproducing.md).

---

## Documentation

| file | what it answers |
|---|---|
| [`docs/overview.md`](docs/overview.md) | **the two gaps**, and the failure message each one gives you. Start here |
| [`docs/building.md`](docs/building.md) | how to build, and the floor rule everything else follows from |
| [`docs/integrating.md`](docs/integrating.md) | how to wire it into a bundle, a plain binary, or a packer |
| [`docs/diagnostics.md`](docs/diagnostics.md) | it did not work, so which layer? A rung by rung procedure |
| [`docs/traps.md`](docs/traps.md) | things that cost somebody a day, for a *user* of this |
| [`docs/limits.md`](docs/limits.md) | what it cannot do, with the measurement behind each |
| [`docs/reproducing.md`](docs/reproducing.md) | how to re-run every number here yourself |
| [`docs/environment.md`](docs/environment.md) | the machine the numbers were measured on |
| [`docs/report/README.md`](docs/report/README.md) | **the measured record.** Every count and every suite total lives here |
| [`docs/ground-truth.md`](docs/ground-truth.md) | where distributions actually keep their libraries, measured |
| [`docs/alternatives.md`](docs/alternatives.md) | the other ways to solve this, and which one fits your position |
| [`docs/rejected-designs.md`](docs/rejected-designs.md) | three designs evaluated and refused, with evidence |
| [`docs/security.md`](docs/security.md) | what a pull request can and cannot do here, and the settings that decide it |
| [`docs/AGENTS.md`](docs/AGENTS.md) | ⭐ the single entry point for an agent working here |
| [`docs/HUMANS.md`](docs/HUMANS.md) | ⭐ what a **person** pastes to get useful work out of a session |
| [`docs/conventions/`](docs/conventions/README.md) | ⛔ how this repository is written. Binding, and half of it is checked by CI |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | what to run and what to read before opening a pull request |
| [`SECURITY.md`](SECURITY.md) | how to report a vulnerability privately |

Not on this list, and not deleted: [`docs/history/`](docs/history/README.md) is
why things are the way they are, in the original wording.
[`docs/todo/`](docs/todo/INDEX.md) is what is open, and the work order is in
[`docs/todo/PROGRESS.md`](docs/todo/PROGRESS.md) and nowhere else.

---

## Runtime switches

| variable | effect |
|---|---|
| `CROSS_LIBC_DLOPEN=0` | turn the feature off. ⭐ It is **on by default** whenever the object is preloaded, so `=1` is only ever a restatement |
| `CROSS_LIBC_DLOPEN_ROOT` | the bundle root. `APPDIR` is read too, because an AppImage runtime exports it on its own |
| `CROSS_LIBC_DLOPEN_LIBDIR` | the bundled library directory under it. Default `lib` |
| `CROSS_LIBC_DLOPEN_DEBUG=1` | trace to stderr |
| `CROSS_LIBC_DLOPEN_RUNTIME` | `host`, `bundled` or `auto`. Forces or auto-selects the libc runtime |
| `CROSS_LIBC_DLOPEN_DRYRUN=1` | report what would be rewritten and what would not resolve, and load nothing |
| `CROSS_LIBC_DLOPEN_NORENAME=1` | disable symbol renaming, to bisect a misbehaving driver |
| `CROSS_LIBC_DLOPEN_NOSTRIP=1` | keep version tags but still load from the private copy, which separates "the rewrite broke it" from "the path broke it" |
| `CROSS_LIBC_DLOPEN_GL_TARGET` | `host` or `bundled`. Which library the GL shims forward to. Unset is the default and is the right answer |
| `CROSS_LIBC_DLOPEN_GL_HOST_DIR` | colon-separated directories to search first for the SONAME being impersonated |
| `CROSS_LIBC_DLOPEN_GL_EAGER=1` | resolve the whole table before `main()` instead of at first call |
| `CROSS_LIBC_DLOPEN_GL_TRACE=1` | one line per entry point at its first call, so you see what the application *uses* |

---

## The invariants a consumer must not break

| ⛔ | |
|---|---|
| **Exactly one libc family in the process.** The whole design is that a second libc never enters. `tests/invariants.c` asserts it |
| **Bundled sonames win.** Anything the bundle ships must resolve to the bundle's copy. Host directories are a fallback for what the bundle lacks, appended and never inserted |
| **A bundle that ships its own vendor library keeps it.** Forwarding to the host's because the host has none puts two Mesas in one process |
| **A shim that replaces a library exports everything that library exports.** A subset renders `glxgears` and then hands the next application `undefined symbol` |
| **Generated files are regenerated, never edited.** `make shim`, `make gl-syms`, `make gles-syms`. Three checks fail the build on drift |

---

## Layout

```
src/            the implementation
tests/          the probes
experiments/    the shell stages. These are the tests
tools/          generators and analysis
scripts/        build and orchestration
examples/       scripts that run and print a before and an after
inventories/    measured symbol inventories the generators consume
docs/           every document
  report/       the measured record, one file per section
  conventions/  how this repository is written
  history/      why things are the way they are
  todo/         what is open
```

The root holds code, tooling, and three documents a visitor opens without
following a link: this one, [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`SECURITY.md`](SECURITY.md). Everything else written for a reader is under
`docs/`.

---

## Prior art

- [pg83/solo](https://github.com/pg83/solo) completes a **static** binary where
  this completes a **dynamic** one. [`docs/alternatives.md`](docs/alternatives.md)
  compares the two properly, including where solo is the better answer.
- [Anylinux-AppImages](https://github.com/pkgforge-dev/Anylinux-AppImages) is
  the implementation this started from, and its `useful-tools/lib/anylinux.c`
  is what `src/cross-libc-dlopen.c` is a modified version of.
- [Anylinux-sharun](https://github.com/pkgforge-dev/Anylinux-sharun) is the
  launcher that assembles `--library-path`. This loader can only reach a driver
  sharun's path already reaches.
- [QaidVoid/onelf](https://github.com/QaidVoid/onelf) bundles the entire libc
  with an `AT_EXECFN` bootstrap. Its own `docs/guide/cross-libc.md` names the
  wall it then hits, which is the wall this removes.
- [graphitemaster/detour](https://github.com/graphitemaster/detour) drives a
  foreign `ld.so` in-process. It needs a libc-free process, so it does not
  apply to a bundle that carries one.

## Credits

- **@Azathothas** for carrying multiple tests in WSL and prototyping 
  the initial implementation.
- **@Samueru-sama** for the OpenGL gap and the mechanism behind gap 2, arriving
  from outside against a repository that had written it off, plus the
  `mesa-egl` directory fix and a seven-distribution matrix on a real RX 580.
- **@QaidVoid** for the reproduction that cracked the main blocker, and the
  `make shim` defect that was silently disarming the entire musl bridge.

## Licence

MIT. See [`LICENSE`](LICENSE).
