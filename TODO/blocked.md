# Blocked

⭐ Everything here is blocked by hardware, by what a distribution ships, or
by a rule in [`RULES.md`](RULES.md). Nothing on this list is merely
unwritten. If you have a machine that unblocks a row, that row is the work.

### 4.2 What is genuinely BLOCKED

⭐ **This list and 4.0 are different lists and must stay different.** 4.0 is
work that can be done on this machine. Everything here is blocked by hardware,
by what a distribution ships, or by the permission rule in section 8, and
nothing on it is merely unwritten. If you find yourself with a machine that
unblocks a row, that row is the work; if not, the honest thing is to verify what
is here rather than add to it.

⚠ Three rows that were on this list moved to 4.0 and are now CLOSED, because
they turned out not to be blocked: the aarch64 trampolines RUN under qemu-user
(B8), the absent GL entry points are observable at the call (B1), and the
`_glapi_` case had a host that settled it (B3 -- it did not reproduce on Mesa
10.1). They are named here only so nobody restores them.

⚠ **`B7` is on this list now**, having come the other way. Its closure record
in 4.0.1 has the two `ls` commands that establish it and the reason it is
structural rather than a packaging accident.

| Item | Why it is not done | What would unblock it |
|---|---|---|
| **Vulkan on hardware** | Mesa's Vulkan-on-D3D12 driver (`dzn`) is `microsoft-experimental` and Debian does not package it, so every ICD result here is lavapipe. OpenGL *is* on hardware now (E53), through the `d3d12` **Gallium** driver, which Debian does package as `dri/d3d12_dri.so` | build Mesa with `-Dvulkan-drivers=microsoft-experimental`, then re-run the suite against that ICD. Watch for `libd3d12.so` being glibc-built: on Alpine the chain becomes musl-Mesa on a glibc D3D12 layer |
| DRM-native drivers (`radv`, `anv`, `radeonsi`) | there is no `/dev/dri` anywhere on this machine. WSL2 publishes no DRM render nodes, so these three cannot initialise however much silicon is present | a non-WSL Linux host |
| The unmeasured plugin boundaries | `libva`, `libvdpau`, `libasound`, `libpulse`, `libOpenCL` and `libgbm` are the same shape as the OpenGL one and this AppDir bundles none of them, so there is nothing here to measure. `tools/plugin_boundaries.py` classifies them on sight if one turns up. `libX11.so.6` IS bundled and its loadable-i18n boundary is unmeasured. ⭐ **This row is out of date and the correction is the next item below** | an AppImage that bundles one of them -- and one now does |
| **Hardware GL on the CLASSIC-Mesa path (B7)** | there is no host on this machine that is both classic-Mesa and able to reach a GPU. The only GPU route here is Mesa's `d3d12` Gallium driver over `/dev/dxg`, which needs Mesa >= 21; every glibc distro at Mesa >= 21 uses libglvnd, and the classic holdouts are musl distros that do not build `d3d12`. Measured: Alpine 3.22 ships no `d3d12_dri.so`, and `/usr/lib/wsl/lib` ships no GL, GLX or EGL at all | a machine with a DRM render node and a classic-Mesa distro. Reported working on an RX 580 from outside, by @Samueru-sama; not reproduced here |
| **Ubuntu 12.04's EGL (B10)** | Mesa 8.0.4 ships EGL 1.4 and, per the same outside report, `eglInitialize` fails there even with the right directory. Not measured here -- 12.04 is on `old-releases` and was not added as a host -- and it is the host's Mesa either way: 16.04's EGL fails the same probe NATIVELY, with no AppImage in the process (E79) | nothing in this repository. An AppImage cannot give a host an EGL implementation it does not have |
| No host implementation for 1097 of the GL entry points | a property of Alpine's Mesa 25.1, not of this repository: they are extensions glvnd knows the names of and that Mesa has no code for. Making the absent case OBSERVABLE was B1 and is DONE -- a call to one is a line naming it, and `glprobe` reaches zero of the 1097 (4.0.1). Making Mesa implement them is not this project's work | nothing here. See B1 |
| **Nine unclassified loaders in the gtk4 AppDir** | measured, not guessed: `python3 tools/plugin_boundaries.py .tmp/gtk4x/AppDir --check` reports `covered 2, n/a 1, unmeasured 3, UNCLASSIFIED 9`. Two of the three `unmeasured` are `libgbm.so.1` and `libva.so.2`, which the row above says this repository has no AppImage for -- it does now. ⭐ And one of the nine is **`libepoxy.so.0`**, which is itself a GL entry-point loader: it `dlopen`s `libGL`/`libEGL`/`libGLESv2` by soname and resolves through them, which is the same DISPATCHER shape as libglvnd and is very likely why gtk4-demo's counts are 1 GL and 46 GLES (E83). Nobody has looked at it | nothing. It is not blocked, it is unexamined, and it is the cheapest lead in this file: `libepoxy.so.0` first, then the other eight. ⛔ Do not assume it is benign because GTK4 rendered -- `libdecor-0.so.0` was benign and `libGLX.so.0` was the whole of section 9 |
| The two live ABI hazards | `regoff_t` is 4 bytes on glibc and 8 on musl, and the `FTW_*` values are off by one, so a musl-built object reads a glibc-filled `regmatch_t[]` or classifies an `nftw` entry wrongly (E50). An offset compiled into an object is not reachable from a preload | nothing in this repository. It is a property of the two libcs, and the useful output is the list of two, which E50 keeps honest |
| Three residual library-path gaps upstream | the sharun fix is **upstreamed** ([Anylinux-sharun@`54208d2`](https://github.com/pkgforge-dev/Anylinux-sharun/commit/54208d2bc7d4c919ba46a6c234f6af7f8426b537)) and the patch here is deleted. What that change does not reach is musl's `/etc/ld-musl-<arch>.path`, multiarch triplets past three, and the non-FHS prefixes; `../docs/ground-truth.md` has the measurement | a different repository, and section 8 forbids writing there |

---

## Two of the rows above are not blocked any more

⛔ **The rows keep their wording**, because the row is how each item has always
been referred to and a silently edited premise is a record of nothing. The
correction goes here.

### "Nine unclassified loaders in the gtk4 AppDir" -- never was blocked

The row says so itself, in its own last column: *"it is not blocked, it is
unexamined, and it is the cheapest lead in this file"*. It is now
[`measurement.md`](measurement.md) **T-02**, with an acceptance command.

### "The two live ABI hazards" -- blocked by the wrong reason

The row says the hazards are *"a property of the two libcs"* and that *"an
offset compiled into an object is not reachable from a preload"*.

⭐ **The measurement is right and the reason is imprecise.** It holds for a
preload that interposes only `dlopen`. It does not hold for one that interposes
the **call**: `pg83/solo` repairs both hazards that way, at
`lib/glibc_shim.cpp:3092` (`regexec`) and `:3460` (`nftw`), and the shapes are
quoted in
[`../HISTORY/references/solo-usable.md`](../HISTORY/references/solo-usable.md) §1.

The work is [`measurement.md`](measurement.md) **T-06**. ⚠ It is bounded, not
free: interposing where the direction of a call is ambiguous translates
something that needed no translation, which is a new defect of the same family.

### Everything else on the list stands

Seven rows remain genuinely blocked, each by hardware, by what a distribution
ships, or by a rule in [`RULES.md`](RULES.md).
