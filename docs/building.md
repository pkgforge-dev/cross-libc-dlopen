# Building

```bash
sh scripts/build.sh
```

That is the whole of it on a machine with `podman` or `docker`. Everything lands
in `build/<arch>/` with a manifest beside it.

⚠ **On Windows, in Git Bash, prefix it.** MSYS rewrites anything that looks
like a path before the container engine sees it, so a bind mount arrives
mangled and the build fails with `invalid option type`. Nothing in the scripts
depends on this; it is the environment:

```bash
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' sh scripts/build.sh
```

---

## The floor rule

⛔ **Build on the OLDEST glibc you intend to support, never the newest.**

Everything else here follows from this, and it is the one that looks like a
detail. A build on glibc 2.41 emits references to `GLIBC_2.34` symbols. The
artefact loads perfectly on the machine that built it, and then fails to load
inside a bundle whose glibc is older. That happens at `dlopen` time, in
somebody else's application, with a message about a symbol version rather
than about a build.

The floor is a **property of the build environment**, which is why the default
is a container: it is the only portable way to pin one. The shipped builds use
`debian:bullseye-slim` (glibc 2.31), and the artefacts come out needing at most
`GLIBC_2.16`.

`scripts/build.sh --engine native` exists for a maintainer already on the floor
distribution. It **refuses, by name**, when the detected host glibc is newer
than the requested floor:

```
build: REFUSING: this host has glibc 2.41, newer than the requested floor 2.31.
```

⚠ It also refuses when it cannot read a glibc version at all, rather than
guessing. `ldd --version` answers on musl and on MSYS too, with *their* version,
which compared against a glibc floor is a number that means nothing.

---

## What gets built, and the constraint on each

| artefact | constraint |
|---|---|
| `cross-libc-dlopen.so` | must need no symbol newer than the floor |
| `gl-fwd.so` | SONAME **must** be `libGL.so.1`. ⚠ It should also carry the IBT property note and currently does not: no Debian gcc emits one, measured on three. See [`REPORT.md`](REPORT.md) 9 and `TODO/infrastructure.md` T-17 |
| `egl-fwd.so` | SONAME **must** be `libEGL.so.1` |
| `gles-fwd.so` | SONAME **must** be `libGLESv2.so.2`; its table comes from an AppDir that BUNDLES GLES, which the host-drivers demo does not |
| `runtime-select` | a normal executable, same floor rule |

Each is checked **after** it is built, by
[`scripts/verify-artifacts.sh`](../scripts/verify-artifacts.sh), against three
properties that all fail *silently* rather than loudly:

- **the SONAME.** A shim whose SONAME is not the library it replaces still
  loads. `ld.so` never binds anything to it, so it forwards nothing and
  nothing says why.
- **the export count.** A shim exporting fewer entry points than its table
  declares hands some application `undefined symbol`, not at load, but at
  whichever call the missing one turns out to be.
- **the maximum `GLIBC_*` requirement.** The floor rule, measured rather than
  assumed.

The manifest records all three per artefact, plus the source hashes, the
compiler and the floor.

---

## Options

```bash
sh scripts/build.sh --check                 # detect and report, build nothing
sh scripts/build.sh --arch aarch64          # cross-build
sh scripts/build.sh --arch both             # both, sequentially
sh scripts/build.sh --engine docker
sh scripts/build.sh --floor-image debian:bookworm-slim --floor-glibc 2.36
```

⭐ `--check` first, on an unfamiliar machine. A script that fails at step nine
because a tool was missing at step one is worse than one that refuses at step
one.

---

## aarch64

A first-class target, not a check. It is cross-compiled inside the x86-64 floor
image, which needs `gcc-aarch64-linux-gnu` **and** `libc6-dev-arm64-cross`.
The compiler alone has no headers and the build dies on `dirent.h`, which
reads like a source bug.

⛔ **Do not reach for `podman run --platform linux/arm64` to get there.** Pulling
a tag for another platform **replaces the cached image for that tag**, and the
next x86-64 job using that image dies with `Exec format error`. That cost a run.

Two Makefile targets exercise the aarch64 trampolines directly:

```bash
make -C src gl-fwd-asm-check    # do they assemble
make -C src gl-fwd-qemu-check   # do they RUN, under qemu-user
```

⚠ qemu emulates the instructions, not a memory model. Real ARM silicon is what
closes that, and CI's `ubuntu-24.04-arm` runner is where it happens. It is
the one place CI is stronger than the machine this project was measured on.

---

## Regenerating what is generated

⛔ Never hand-edit `src/forward-shim.c` or `src/gl-fwd-*.h`.

```bash
make -C src shim                             # forward-shim.c
make -C src gl-syms   GLVND="$APPDIR/lib"    # the GL and EGL tables
make -C src gles-syms GLES="$APPDIR/lib"     # the GLES table
make -C src traps AUDIT_LIBC=/path/to/libc.so.6
```

⚠ `make shim` must be passed a musl inventory. Omitting it drops most of the
definitions and silently disarms the entire musl bridge. That is why `MUSL` has
a default in the Makefile rather than being something the caller must remember;
it was reported from outside by @QaidVoid after the documented command produced
a different artefact from the shipped one.

The `-check` variants fail the build on drift and run in CI. ⚠ `gles-syms-check`
**skips with exit 0** when there is no AppDir bundling `libGLESv2.so.2`, so it
only means anything in a job that has extracted one. That is why it lives in
[`appimage-suite.yml`](../.github/workflows/appimage-suite.yml) and not in the
fast gate.
