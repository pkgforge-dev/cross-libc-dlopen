# examples

Every example here is a script that runs and prints a **before** and an
**after**. Every claim about another project cites a file in that project.
⭐ **A target this does not help is listed with the reason**, because a section
that strains to include a project it does not help is worse than an honest
exclusion.

| example | what it shows | status |
|---|---|---|
| [`plain-preload/`](plain-preload/) | a glibc process opening a musl-built object, with **no AppDir, no marker and no `.preload`** anywhere | runs |
| [`appimage-gl-shims/`](appimage-gl-shims/) | adding the three GL shims to an AppDir built by `quick-sharun`, before and after, on a musl host | runs, by driving the suite's own stage |

---

## Anylinux-AppImages

[`pkgforge-dev/Anylinux-AppImages`](https://github.com/pkgforge-dev/Anylinux-AppImages)
-- shell. The project this work started from and its first consumer. ⚠ No longer
its only intended one.

Verified present at the time of writing:

| path | what it is |
|---|---|
| `useful-tools/lib/anylinux.c` | the upstream foreign-dlopen implementation this one is a modified version of |
| `useful-tools/quick-sharun.sh` | builds AppDirs |
| `useful-tools/demo/vkcube-glxgears-appimage.sh` | the exact demo this repository has been testing against |
| `useful-tools/demo/` | also gtk2/gtk3/gtk4, qt6-dbus, sdl, webkit2gtk4 and bun recipes |
| `useful-tools/hooks/` | a hook system, documented in its own `hook-system.md` |
| `useful-tools/uruntime2appimage.sh` | repacking |

**The example** is [`appimage-gl-shims/`](appimage-gl-shims/): take a demo
recipe, add `gl-fwd.so`, `egl-fwd.so` and `gles-fwd.so` to the AppDir's
`.preload`, and show the before and the after on a musl host.

⚠ **What it found:** a self-contained AppImage that bundles its own vendor
library must **keep** it. Forwarding to the host's because the host has none
puts two Mesas in one process. `experiments/47-gtk4.sh` is that case and is the
shortest thing to read first.

---

## Anylinux-sharun

[`pkgforge-dev/Anylinux-sharun`](https://github.com/pkgforge-dev/Anylinux-sharun)
-- Rust. The launcher fork that assembles `--library-path` for the bundled
runtime. Relevant files: `src/main.rs`, `src/utils.rs`.

It already carries the library-path completeness fix this repository used to
ship as a patch:
[`54208d2`](https://github.com/pkgforge-dev/Anylinux-sharun/commit/54208d2bc7d4c919ba46a6c234f6af7f8426b537),
*"add more directories to `--library-path`"*, verified to exist under that
message.

⭐ **The coupling is the point.** This loader can only reach a host driver that
sharun's `--library-path` already reaches. `SHARUN_FALLBACK_LIBRARY_PATH` is the
supported way to extend it without editing anything. A driver whose directory is
named only in `/etc/ld.so.cache` is invisible without it, measured in E45,
where the CUDA round trip fails until that directory is added and succeeds once
it is. See [`docs/ground-truth.md`](../docs/ground-truth.md) for the three gaps
that fix does *not* reach.

---

## onelf

[`QaidVoid/onelf`](https://github.com/QaidVoid/onelf), a Rust workspace, "pack
entire directories into self-contained executables". Verified present:
`crates/onelf/src/bundle/gpu.rs`, `crates/onelf-format/src/drivers.rs`,
`docs/guide/cross-libc.md`.

⚠ **onelf solves a different half of the same problem, and the contrast is the
example.** It bundles the *entire* libc and injects an `AT_EXECFN` bootstrap
into each bundled executable; the bootstrap maps the bundled loader and jumps
into it, so, in its own words, the host's own loader is never consulted and a
musl binary runs on a glibc host without host-level setup.

Its own `docs/guide/cross-libc.md` then states the wall it hits, under the
heading *Packaging musl apps on glibc hosts*: the host's `libdrm`, `libgcc_s`,
`libpthread` and the rest are all glibc-linked, so its bundler cannot use them,
and its documented answer is to obtain musl-built versions (it shows doing this
through Nix cross-compilation).

⭐ **That wall is exactly what this project removes.** Where onelf needs a
musl-built `libdrm`, this rewrites the glibc one in a private copy so the
family stops mattering.

⛔ **UNVERIFIED:** no onelf bundle has been driven through this loader here. The
contrast above is read out of onelf's own documentation and source layout, not
measured. [`TODO/measurement.md`](../TODO/measurement.md) T-03 is where the
measurement belongs.

---

## runimage: this project does not apply, and here is why

[`VHSgunzo/runimage`](https://github.com/VHSgunzo/runimage), a shell project, "portable
single-file linux container". Verified present: `rootfs/`, `RunDir` (a symlink),
`examples/` with alpine, debian, fedora, ubuntu, void and steam recipes.

**It does not have the problem this project solves**, and its own README says
what it does instead. runimage carries a complete root filesystem, so an
application inside it links that userland's libc, not the host's: there is no
bundled-glibc-meets-host-musl boundary to bridge.

For the GPU it takes the opposite approach: rather than loading the host's
driver, it **supplies a matching one**. Its README documents building or
downloading an NVIDIA driver image whose version matches the host's
(`$RUNIMAGEDIR/{nvidia_version}.nv.drv`), with `RIM_SYS_NVLIBS=1` as an opt-in
to try the host's libraries instead and `RIM_NVIDIA_DRIVERS_DIR` to point at a
directory of driver images.

⭐ **That is a coherent and different answer**, and it costs a driver-sized
download rather than a shim. The one place the two could meet is
`RIM_SYS_NVLIBS=1`, where runimage does reach for host libraries, and if that path
ever hits a libc-family mismatch, this loader is what would bridge it.
⛔ **UNVERIFIED:** not tested, and not claimed.

---

## Static and conventionally-linked binaries

⚠ **"Static binaries cannot `dlopen`" is the wrong answer.** Three distinct
cases, all three currently **UNVERIFIED**, written down as questions rather than
answers in [`docs/limits.md`](../docs/limits.md) and carried as work in
[`TODO/measurement.md`](../TODO/measurement.md) T-01.

The `plain-preload` example above covers the *third* of those three shapes in
part, a normally dynamically linked program, and says so.
