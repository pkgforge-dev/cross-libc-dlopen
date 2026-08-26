# cross-libc `dlopen`

**Load the host's GPU drivers into a process that carries its own libc.**

A bundled application ships its glibc so it runs anywhere. It does not ship GPU
drivers, because Mesa plus LLVM is 100 to 200 MB, so it has to borrow the
host's. Two separate things stop it, and they give different symptoms.

| | the gap | what you see |
|---|---|---|
| **1** | the host's driver was built against a **different libc**: a newer glibc, or musl | `version 'GLIBC_2.38' not found`, or `libc.musl-x86_64.so.1: cannot open shared object file` |
| **2** | the host has the capability but ships **nothing in the shape the bundled loader looks for**, with no `libGLX_<vendor>.so.0` behind libglvnd | ⭐ `couldn't get an RGB, Double-buffered visual`, a message about visuals for a fault about neither visuals nor libc |

Gap 1 is repaired by an `LD_PRELOAD`ed `dlopen` interposer. It rewrites the host
object in a private copy so its symbol version requirements stop mattering. Gap
2 is repaired by an object built with the **SONAME of the library it replaces**,
so `ld.so` binds the application's `DT_NEEDED` to it and every entry point of
the bundled dispatcher forwards to whatever the host can stand behind.

⭐ **This is a preload, not an AppImage feature.** It needs a dynamically linked
process whose libc differs from the driver's. An AppImage is the hardest such
consumer, because it supplies its own loader as well as its own libc, so it is
what every measured result here was obtained through. Nothing in the mechanism
requires one: [`examples/plain-preload/`](examples/plain-preload/) runs it
against an ordinary binary with no AppDir anywhere.

⚠ **What has not been measured** is a non-AppImage process against a real GPU
driver, so this page does not claim one.
[`TODO/measurement.md`](TODO/measurement.md) T-03 is that work.

---

## Quick start

```bash
sh scripts/build.sh
```

It detects `podman`, `docker` or a native toolchain, reports what it found
before building anything, and writes every artefact plus a manifest under
`build/`. Then, for any dynamically linked program:

```bash
LD_PRELOAD=/path/to/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 ./your-program
```

For a bundle, put `cross-libc-dlopen.so`, `gl-fwd.so`, `egl-fwd.so` and
`gles-fwd.so` in the bundle's `lib/` and name them in `.preload`.
[`docs/integrating.md`](docs/integrating.md) has the detail per target.

⛔ **Build on the oldest glibc you intend to support, never the newest.** A
build on a new glibc emits references to symbol versions an older bundled glibc
does not have, so the artefact fails to load inside somebody else's application
rather than failing at your build. `scripts/build.sh` defaults to a container
for that reason and refuses a native build, by name, when the host is newer
than the floor. [`docs/building.md`](docs/building.md).

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

## What was demonstrated, and on what

⭐ **Every count and every suite total lives in
[`docs/REPORT.md`](docs/REPORT.md) and nowhere else.** This table says what was
shown and where; REPORT says how much.

| result | the host it was measured on |
|---|---|
| a musl-built Vulkan ICD driving `vkcube`, where as shipped it reports zero devices | Alpine 3.22, musl, classic Mesa |
| `glxgears` rendering, with a cleared pixel read back correctly | Alpine 3.22, musl, no glvnd vendor library anywhere |
| OpenGL and EGL complete on a **pre-glvnd glibc** host | `ubuntu:14.04` at glibc 2.19, `ubuntu:16.04` at glibc 2.23 |
| turning the feature on breaking nothing that already worked, with zero objects rewritten where none needs it | `debian:trixie-slim`, glibc 2.41, older than the bundled 2.44 |
| a **closed-source** driver, 4096 bytes round-tripped through the GPU and verified | NVIDIA RTX 3050 Ti, through `/dev/dxg` |
| a real GTK4 application, and the finding that its renderer is **GLES** rather than GL | `gtk4-demo`, on musl Alpine |
| the host libc runtime swapped in at `execve` time, with a driver on the end | `debian:trixie-slim` |
| a plain `LD_PRELOAD` against an ordinary binary, with **no AppDir, no marker and no `.preload`** | `debian:bullseye-slim` loading a musl object |

⚠ What is **not** measured is [`docs/limits.md`](docs/limits.md), and it is a
list rather than a silence.

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
| [`docs/REPORT.md`](docs/REPORT.md) | ⭐ **the measured record.** Every count and every suite total lives here |
| [`docs/ground-truth.md`](docs/ground-truth.md) | where distributions actually keep their libraries, measured |
| [`docs/alternatives.md`](docs/alternatives.md) | the other ways to solve this, and which one fits your position |
| [`docs/rejected-designs.md`](docs/rejected-designs.md) | three designs evaluated and refused, with evidence |
| [`docs/AGENTS.md`](docs/AGENTS.md) | ⭐ the single entry point for an agent working here |
| [`docs/HUMANS.md`](docs/HUMANS.md) | ⭐ what a **person** pastes to get useful work out of a session |
| [`docs/conventions/`](docs/conventions/README.md) | ⛔ how this repository is written. Binding, and half of it is checked by CI |

Not on this list, and not deleted: [`HISTORY/`](HISTORY/README.md) is why things
are the way they are, in the original wording. [`TODO/`](TODO/INDEX.md) is what
is open, and the work order is in
[`TODO/PROGRESS.md`](TODO/PROGRESS.md) and nowhere else.

---

## Runtime switches

| variable | effect |
|---|---|
| `CROSS_LIBC_DLOPEN=1` or `=0` | force the feature on or off. `=0` is the A/B control |
| `CROSS_LIBC_DLOPEN_ROOT` | the bundle root. `APPDIR` is also accepted |
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
src/               the implementation
experiments/       the shell stages. These are the tests
tests/             the probes
tools/             generators and analysis
scripts/           build and orchestration
docs/              what it does, how to use it, what it cannot do
examples/          scripts that run and print a before and an after
HISTORY/           why things are the way they are
TODO/              what is open
```

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

- **@Samueru-sama** for the OpenGL gap and the mechanism behind gap 2, arriving
  from outside against a repository that had written it off, plus the
  `mesa-egl` directory fix and a seven-distribution matrix on a real RX 580.
- **@QaidVoid** for the reproduction that cracked the main blocker, and the
  `make shim` defect that was silently disarming the entire musl bridge.

## Licence

MIT. See [`LICENSE`](LICENSE).
