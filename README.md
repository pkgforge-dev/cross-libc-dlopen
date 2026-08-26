# cross-libc `dlopen`

**Make an AppImage use the host's GPU drivers.**

An AppImage bundles its own glibc so it runs anywhere. It does **not** bundle
GPU drivers -- Mesa plus LLVM is 100-200 MB -- so it has to use the host's. Two
different things stop it:

| | the gap | what you see |
|---|---|---|
| **1** | the host's driver exists and was built against a **different libc** -- a newer glibc, or musl | `version 'GLIBC_2.38' not found`, or `libc.musl-x86_64.so.1: cannot open shared object file` |
| **2** | the host has the capability and ships **nothing in the shape the bundled loader looks for** -- no `libGLX_<vendor>.so.0` behind libglvnd | ⭐ `couldn't get an RGB, Double-buffered visual` -- a message about visuals, for a fault about neither visuals nor libc |

Gap 1 is repaired by an `LD_PRELOAD`ed `dlopen` interposer that rewrites the
host object in a private copy so its symbol version requirements stop mattering.
Gap 2 is repaired by an object built with the **SONAME of the library it
replaces**, so `ld.so` binds the application's `DT_NEEDED` to it, forwarding
every entry point of the bundled dispatcher to whatever the host can stand
behind.

⚠ **Scope, stated plainly.** Every measured result below was obtained through a
real AppImage, which is the hardest consumer because it supplies its own loader.
The code no longer *requires* one -- [`examples/plain-preload/`](examples/plain-preload/)
runs it against an ordinary binary with no AppDir anywhere -- but a non-AppImage
run against a real GPU driver has not been measured, so this page does not claim
one. See [`TODO/measurement.md`](TODO/measurement.md) T-03.

---

## Quick start

```bash
sh scripts/build.sh
```

Detects `podman`, `docker` or a native toolchain, says what it found **before**
building anything, and produces every artefact in `build/<arch>/` with a
manifest. Then:

```bash
LD_PRELOAD=/path/to/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 ./your-program
```

For an AppImage, add `cross-libc-dlopen.so`, `gl-fwd.so`, `egl-fwd.so` and
`gles-fwd.so` to the AppDir's `lib/` and name them in `.preload`.
[`docs/integrating.md`](docs/integrating.md) has the details per target.

⛔ **Build on the oldest glibc you intend to support, never the newest.** A
build on a new glibc emits references to symbol versions an older bundled glibc
does not have, and the artefact then fails to load inside somebody else's
application rather than failing at your build. `scripts/build.sh` defaults to a
container for exactly this reason and refuses a native build, by name, when the
host is newer than the floor. [`docs/building.md`](docs/building.md).

---

## What was demonstrated, and where

⭐ **Every count and every suite total lives in
[`docs/REPORT.md`](docs/REPORT.md) and nowhere else** -- one fact, one home. This
table says *what* was shown and on *which host*; REPORT says how much.

| result | the host it was measured on |
|---|---|
| a musl-built Vulkan ICD driving `vkcube`, where as shipped it reports zero devices | Alpine 3.22, musl, classic Mesa |
| `glxgears` rendering, and a cleared pixel read back correctly, through the GL forwarding table | Alpine 3.22, musl, no glvnd vendor library anywhere |
| OpenGL and EGL complete on a **pre-glvnd glibc** host | `ubuntu:14.04` (glibc 2.19, Mesa 10.1) and `ubuntu:16.04` (glibc 2.23, Mesa 18.0.5) |
| turning the feature on breaking nothing that already worked -- zero objects rewritten where none needs it | `debian:trixie-slim`, glibc 2.41, **older** than the bundled 2.44 |
| a **closed-source** driver: 4096 bytes round-tripped through the GPU and verified | NVIDIA RTX 3050 Ti, via `/dev/dxg`, from the AppImage's bundled glibc on Alpine |
| rendering on that GPU, `GL_RENDERER = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)`, over 100 FPS | the same machine, through Mesa's `d3d12` Gallium driver |
| a real GTK4 application, and the finding that its renderer is **GLES** rather than GL | `gtk4-demo`, on musl Alpine |
| the host libc runtime swapped in at `execve` time, with a driver on the end | `debian:trixie-slim` |
| a plain `LD_PRELOAD` against an ordinary binary, **no AppDir, no marker, no `.preload`** | `debian:bullseye-slim` loading a musl object |

⚠ Everything above came from **one machine**, described in
[`docs/environment.md`](docs/environment.md). CI on a second architecture is
written and has not yet run. What is **not** measured is
[`docs/limits.md`](docs/limits.md), and it is a list rather than a silence.

---

## Reproducing it

```bash
sh scripts/run-evidence.sh      # ~4 minutes. The pre-commit gate.
```

```bash
sh scripts/run-appimage.sh      # tens of minutes. The end-to-end proof.
```

Both need `podman` or `docker` and nothing else.
[`docs/reproducing.md`](docs/reproducing.md).

---

## The invariants a consumer must not break

| ⛔ | |
|---|---|
| **Exactly one libc family in the process.** The whole design is that a second libc never enters. `tests/invariants.c` asserts it |
| **Bundled sonames win.** Anything the bundle ships must resolve to the bundle's copy; host directories are a fallback for what the bundle lacks, appended and never inserted |
| **A bundle that ships its own vendor library keeps it.** Forwarding to the host's because the host has none puts two Mesas in one process |
| **A shim that replaces a library exports everything that library exports.** A subset is not a smaller version of this design: it renders `glxgears` and hands the next application `undefined symbol` |
| **Generated files are regenerated, never edited.** `make shim`, `make gl-syms`, `make gles-syms`. Three checks fail the build on drift |

---

## Runtime switches

| variable | effect |
|---|---|
| `CROSS_LIBC_DLOPEN=1` / `=0` | force the feature on or off. `=0` is the A/B control |
| `CROSS_LIBC_DLOPEN_ROOT` | the bundle root. `APPDIR` is also accepted |
| `CROSS_LIBC_DLOPEN_LIBDIR` | the bundled library directory under it. Default `lib` |
| `CROSS_LIBC_DLOPEN_DEBUG=1` | trace to stderr |
| `CROSS_LIBC_DLOPEN_RUNTIME=host\|bundled\|auto` | force or auto-select the libc runtime |
| `CROSS_LIBC_DLOPEN_DRYRUN=1` | report what would be rewritten and what would not resolve; load nothing |
| `CROSS_LIBC_DLOPEN_NORENAME=1` | disable symbol renaming, to bisect a misbehaving driver |
| `CROSS_LIBC_DLOPEN_NOSTRIP=1` | keep version tags but still load from the private copy -- separates "the rewrite broke it" from "the path broke it" |
| `CROSS_LIBC_DLOPEN_GL_TARGET=host\|bundled` | which library the GL shims forward to. Unset is the default and is the right answer |
| `CROSS_LIBC_DLOPEN_GL_HOST_DIR=<dir>[:…]` | directories to search first for the SONAME being impersonated |
| `CROSS_LIBC_DLOPEN_GL_EAGER=1` | resolve the whole table before `main()` instead of at first call |
| `CROSS_LIBC_DLOPEN_GL_TRACE=1` | one line per entry point at its first call: what the application *uses* |

⚠ The old `ANYLINUX_*` spellings are still read as deprecated aliases, so a
bundle built before the rename keeps working. [`src/cld-env.h`](src/cld-env.h)
says why in full.

---

## Layout

```
src/            the implementation
experiments/    the shell stages -- ⛔ these are the tests
tests/          the probes
tools/          generators and analysis
scripts/        build and orchestration
docs/           what it does, how to use it, what it cannot do
docs/AGENTS.md  the single entry point for an agent
docs/HUMANS.md  the prompts a person pastes to get work out of a session
docs/conventions/  how this repository is written. Binding
examples/       scripts that run and print a before and an after
HISTORY/        why things are the way they are
TODO/           what is open. The work order is in TODO/PROGRESS.md
```

---

## Four ways to ship a Linux binary that needs the GPU

The GPU driver is always the host's, always a shared object, and almost always
built against glibc. Everything below is a different answer to that one fact.

| | what you ship | GPU on a foreign-libc host | what it costs you |
|---|---|---|---|
| **A static binary** | one musl-static file, no dependencies | ⛔ **no.** A fully static musl binary cannot `dlopen` the host's glibc driver at all | you must be able to build your whole application musl-static |
| **A static binary + [`solo`](https://github.com/pg83/solo)** | the same file, plus solo's `libdlfcn.a` | **yes**, through solo's own ELF loader and glibc-ABI bridge | the same musl-static build, and musl's allocator and threading rather than glibc's |
| **A plain AppImage** | your app and its glibc, dynamically linked | ⛔ **no**, on two distinct hosts: one whose driver is a different libc family, and one that ships no glvnd vendor library | nothing. It works everywhere except the GPU |
| **An AppImage + this** | the same AppImage, plus three preloaded objects | **yes**, on both | one `.preload` entry. Nothing about your build changes |

⭐ **The difference that decides it is the precondition, not the mechanism.**
solo's own README asks you to "link the archive into a musl-static
application", built with its companion build system. That is a coherent design
and it is a rebuild of your entire dependency graph. This project's
precondition is that you already have a dynamically linked bundle, which is
what an AppImage is.

So the two are not competitors so much as answers for people in different
positions: **solo completes a static binary; this completes an AppImage.**

### The mechanisms, briefly

| | solo | this |
|---|---|---|
| the process | static musl, whose image solo owns entirely | bundled glibc, inside somebody else's process |
| the loader | replaced -- its own ELF loader, symbol-version matching and `ld.so.cache` reader | the host's, untouched. Only `dlopen` is interposed |
| the libc bridge | hand-written, and large | generated from measured symbol inventories, plus a version-trap forwarder set |
| the second gap | not addressed | ⭐ the other half of this project |

⭐ **The second gap is the one most people actually hit, and only one of the two
addresses it.** A host whose Mesa was built without glvnd ships no
`libGLX_<vendor>.so.0`, and no amount of libc bridging carries a file that does
not exist. If your symptom is `couldn't get an RGB, Double-buffered visual`,
that is this gap. solo does not meet it, because a static binary bringing its
own stack never goes looking for a vendor library the host was supposed to
ship.

### The honest verdict

**If you are starting fresh and can build musl-static, solo is the more mature
choice.** Its ABI bridge covers cases this one records as limits, and it is
tested across more host classes than this project has ever run on. That is the
answer even though it is not this project's.

**If you already ship an AppImage, this is the only one of the two that
applies.** Rebuilding a working glibc bundle around a different libc to fix the
GPU is a large change to make for one subsystem, and it is the change solo's
approach requires. A preload is not.

⚠ **Not measured here:** the runtime cost of the musl-static route. musl's
allocator and thread primitives are documented as trading throughput for size
and simplicity, and this project has taken no measurement of either
implementation. Treat it as a trade-off to check for your workload, not as a
number from this repository.

The full sweep of solo's code, at the commit it was read at, is in
[`HISTORY/references/solo-findings.md`](HISTORY/references/solo-findings.md).

---

## Prior art

- [pg83/solo](https://github.com/pg83/solo) -- the reverse direction. Compared
  above.
- [Anylinux-AppImages](https://github.com/pkgforge-dev/Anylinux-AppImages) -- the
  implementation this work started from, and its `useful-tools/lib/anylinux.c`
  is what `src/cross-libc-dlopen.c` is a modified version of.
- [Anylinux-sharun](https://github.com/pkgforge-dev/Anylinux-sharun) -- the
  launcher that assembles `--library-path`. This loader can only reach a driver
  sharun's path already reaches.
- [QaidVoid/onelf](https://github.com/QaidVoid/onelf) -- bundles the entire libc
  with an `AT_EXECFN` bootstrap. Its own `docs/guide/cross-libc.md` names the
  wall it then hits, which is the wall this removes.
- [graphitemaster/detour](https://github.com/graphitemaster/detour) -- driving a
  foreign `ld.so` in-process. Needs a libc-free process, so not applicable to an
  AppImage.

## Credits

- **@Samueru-sama** -- the OpenGL gap and the mechanism behind gap 2, arriving
  from outside against a repository that had written it off; the `mesa-egl`
  directory fix; and a seven-distribution matrix on a real RX 580 covering Mesa
  versions this machine has no access to.
- **@QaidVoid** -- the reproduction that cracked the main blocker, and the
  `make shim` defect that was silently disarming the entire musl bridge.

## Licence

MIT. See [`LICENSE`](LICENSE).
