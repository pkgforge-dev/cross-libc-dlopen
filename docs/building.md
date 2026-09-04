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

⛔ **Build on a glibc no newer than the oldest BUNDLED glibc you intend to
load into.**

⚠ **The host's glibc is not what decides this, and reading it as the host is
the mistake the rule invites.** These artefacts are preloaded into somebody
else's process, and what has to satisfy their symbol version requirements is
the glibc that process CARRIES. A host running a fifteen-year-old distribution
is irrelevant to it.

Measured, building on glibc 2.43:

```
$ objdump -T cross-libc-dlopen.so | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1
GLIBC_2.34
```

`dlopen`, `dlsym`, `dlclose`, `dladdr`, `dlvsym` and `dlinfo` moved into libc at
glibc 2.34, and `stat` and `fstat` at 2.33. A build on any glibc at or above
2.34 therefore needs `GLIBC_2.34`, and a bundle carrying glibc 2.31 does not
have it. The artefact loads perfectly on the machine that built it and then
fails at `dlopen` time in somebody else's application, with a message about a
symbol version rather than about a build.

The same source built on `debian:bullseye-slim` needs at most `GLIBC_2.16`.

⭐ **glibc's backward compatibility is real, and it runs one way.** Both
directions were measured, by preloading the built object onto `/bin/true`:

| built on | requires | loaded into glibc 2.31 | loaded into glibc 2.43 |
|---|---|---|---|
| glibc 2.31 | `GLIBC_2.16` | yes | yes |
| glibc 2.43 | `GLIBC_2.34` | ⛔ `version 'GLIBC_2.34' not found` | yes |

That asymmetry is the whole rule. An old build runs everywhere, which is why
the floor is 2.31 and why the container is the default.

⭐ **So building on the newest glibc is correct whenever every bundle you
target is at least as new.** A build on Arch loads into a bundle carrying
glibc 2.44, and the host underneath can be as old as it likes: that is the gap
this project exists to close. It is only the BUNDLE being older than the build
that breaks, which is why the default is a container and the floor is 2.31.

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
| `gl-fwd.so` | SONAME **must** be `libGL.so.1`. ⚠ It should also carry the IBT property note and currently does not: no Debian gcc emits one, measured on three. See [`report/09-the-second-boundary.md`](report/09-the-second-boundary.md) 9 and `docs/todo/infrastructure.md` T-17 |
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

## Building without the script

⭐ **`make portable` is the packager's target**, and it needs no container, no
script and no patch to this repository:

```bash
cd src && make portable
```

It is `sh scripts/build.sh --portable` with the orchestration taken away, and
it produces the same objects: built with `-DCLD_STRICT_ENV`, and without
`-fcf-protection=full`.

⛔ **`make portable` says nothing about which glibc you build on.** The floor
rule above still decides whether the result loads.

### What the two flags do

| flag | effect |
|---|---|
| `-DCLD_STRICT_ENV` | the objects read `CROSS_LIBC_DLOPEN_ROOT` and ignore `APPDIR`. The default reads both, because an AppImage runtime exports `APPDIR` into every process it starts, and a consumer who wants one spelling asked for this |
| no `-fcf-protection=full` | the build stops REQUESTING CET |

⚠ **Dropping the CET flag removes the request, not always the instructions.** A
toolchain that enables CET by default still emits `endbr64`, and that is the
distribution's choice rather than this project's. Measured on a gcc whose
`-Q --help=common` reports `-fcf-protection=full`: the default and portable
builds carry 202 each, identical. The flag is dropped because it does no
protective work here, which
[`report/09-the-second-boundary.md`](report/09-the-second-boundary.md) 9.13
measures, and because a toolchain that does not support it treats being asked
as a hard error.

⚠ **The Makefile now asks the compiler rather than assuming from the
architecture.** Targeting x86 is not the same as supporting the flag, and the
architecture test alone let an unsupported flag reach a compiler that refuses
it. Most callers therefore never need `portable` for that reason at all.

---

## Options

```bash
sh scripts/build.sh --check                 # detect and report, build nothing
sh scripts/build.sh --arch aarch64          # cross-build (riscv64, ppc64,
                                            # ppc64le and loongarch64 too)
sh scripts/build.sh --arch both             # x86_64 and aarch64, sequentially
sh scripts/build.sh --engine docker
sh scripts/build.sh --portable              # -DCLD_STRICT_ENV, and no CET flag
sh scripts/build.sh --floor-image debian:bookworm-slim --floor-glibc 2.36
```

⭐ `--check` first, on an unfamiliar machine. A script that fails at step nine
because a tool was missing at step one is worse than one that refuses at step
one.

---

## The cross-compiled architectures

aarch64, riscv64, ppc64, ppc64le and loongarch64 are first-class targets, not
checks. Each is cross-compiled inside an x86-64 floor image, which needs the
target's `gcc-<triplet>` **and** its `libc6-dev-<arch>-cross` package. The
compiler alone has no headers and the build dies on `dirent.h`, which reads
like a source bug.

Which floor image a target builds in is a property of the target:

| target | floor image | cross compiler | notes |
|---|---|---|---|
| aarch64, riscv64, ppc64, ppc64le | `debian:bullseye-slim`, floor glibc 2.31 | gcc-10 | measured against the Debian archive indices: all four cross packages exist on bullseye |
| loongarch64 | `debian:trixie-slim`, floor glibc 2.36 | gcc-14 | the port postdates gcc-10, so bullseye has no cross compiler for it. The floor is 2.36 because that is the first glibc release that runs loongarch64 at all, so no older bundle exists to break |

`scripts/build.sh` selects the trixie image for loongarch64 by itself; a
`--floor-image` you pass wins over that.

⛔ **Do not reach for `podman run --platform linux/<arch>` to get there.** Pulling
a tag for another platform **replaces the cached image for that tag**, and the
next x86-64 job using that image dies with `Exec format error`. That cost a run.

Two Makefile targets exercise the hand-written trampolines directly, for every
architecture in the list above:

```bash
make -C src gl-fwd-asm-check    # do they assemble
make -C src gl-fwd-qemu-check   # do they RUN, under qemu-user
```

The qemu check is stronger than a smoke run: it passes one argument of every
register class through a trampoline (integer, long, double, pointer), calls
each entry point twice so the patched slot is taken as well as the resolver,
checks a double return value, and calls a name the target does not define so
the absent stub is exercised. On ppc64 it runs the ELFv1 descriptor hop
through the host's real `ld64.so.1`, and on ppc64le the ELFv2 global-entry
TOC rebuild.

⚠ qemu emulates the instructions, not a memory model. Real silicon is what
closes that, and CI's `ubuntu-24.04-arm` runner is where it happens for
aarch64. It is the one place CI is stronger than the machine this project was
measured on. ⚠ The other four architectures have no such runner: their
trampolines have run under qemu-user and nowhere else, which
[`report/10-measured-versus-assumed.md`](report/10-measured-versus-assumed.md)
records. ⚠ loongarch64 additionally needs a qemu new enough for the sysroot's
glibc: measured, qemu 7.2 faults on trixie's glibc 2.41 where 10.0 runs it.

⚠ A ppc64 (big-endian, ELFv1) link on bullseye's binutils prints
`unexpected reloc type 38 in .opd section` and exits 0. The output is correct:
the `.opd` entries come out as `R_PPC64_RELATIVE` dynamic relocations and the
object runs. Measured by running it, not by trusting the exit code.

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
