# Reproducing the measurements

Two suites. The first is a four-minute gate; the second takes tens of
minutes and is the end-to-end proof.

## 3. Reproduce the current state

### 3.1 The evidence table (3 minutes, the regression gate)

```bash
sh scripts/run-evidence.sh
```

or, on a machine with PowerShell and no POSIX shell:

```powershell
.\experiments\run.ps1
```

Every prediction must hold. ⭐ **The expected totals live in
[`REPORT.md`](REPORT.md) and nowhere else** -- one fact, one home, so a number
that moves moves in one file. Run this before every commit. A MISMATCH is a
finding, not a harness bug: investigate before coding.

Three container stages over one shared volume: `alpine:3.22` builds a faithful
musl probe, `debian:trixie-slim` (glibc 2.41) builds libraries needing new
symbols, `debian:bullseye-slim` (glibc 2.31) plays "an AppImage bundling an
older glibc" and runs the tests. The repo is mounted at `/repo`, so cases
E14-E29 build and test `src/` as it actually ships.

### 3.2 The musl symbol gap (Tier 0, no Linux needed)

```bash
mkdir -p /tmp/gap && cd /tmp/gap
py -3 "$REPO/tools/gap.py" --fetch
```

Expect the union over the Mesa+LLVM closure to be exactly
`['___environ', 'atexit']`.

### 3.3 The end-to-end proof (35 minutes the first time)

```powershell
.\experiments\appimage.ps1                  # all five stages
.\experiments\appimage.ps1 -Only ubuntu1404 # or one of them
```

The POSIX form, which is what CI runs:

```bash
sh scripts/run-appimage.sh
sh scripts/run-appimage.sh --only ubuntu1404
```

Five stages, not two: `alpine:3.22` (musl, classic Mesa), `debian:trixie-slim`
(glibc, glvnd), `ubuntu:14.04` and `ubuntu:16.04` (glibc, **pre-glvnd** -- the
third host class), and a fifth that is not a host at all but a different
APPIMAGE: a real GTK4 application that bundles its own Mesa. `-Only` takes
`alpine`, `debian`, `ubuntu1404`, `ubuntu1604`, `gtk4`, `both` or `all`.

Each host has its own expected total and its own named skips.
[`REPORT.md`](REPORT.md) §8 carries all five, with the host each came from.
It downloads the demo AppImage once into `.tmp` (sha256 verified), extracts it
inside a container because the payload is DwarFS, builds `src/` on the glibc
2.31 **floor**, builds the musl half of the ABI probe on Alpine, and then runs
the same suite on each host. The gtk4 stage downloads a second AppImage
(~30 MB, sha256 verified) and extracts it into its OWN directory -- the two
AppDirs are different shapes and mixing them is not hypothetical; section 5.

⚠ **The two Ubuntu hosts have no Vulkan at all** -- Mesa 10.1 predates it -- so
sections A-E and H SKIP by name there while F, G and J still run. That is why
their totals are 26 and not 45, and the nineteen skips are the count of what
those hosts cannot be asked rather than of anything that failed.

**On a machine with no GPU the count is lower and that is correct.** The driver
probes for `/dev/dxg` plus a bind-mountable `/usr/lib/wsl` by running a
throwaway container, and when either is absent E41-E53 are SKIPPED with the
capability named. The five skips on Alpine here are the same mechanism: no host
glibc runtime to switch to (E51, E52) and no d3d12 driver (E53a, E53, E53b).

Every case runs the feature **off and on**, and against **both** the
`cross-libc-dlopen.so` shipped inside the AppImage and the one built from `src/`.
That is not thoroughness for its own sake: see section 6, where "it rendered
with the feature off" turns out not to mean what it looks like.

The headline rows, on Alpine:

```
E30  AppImage as shipped, feature on   NO-DEVICES  (segfault)
E31  control, feature off              NO-DEVICES  (VK_ERROR_INCOMPATIBLE_DRIVER)
E32  this repo, feature on             DEVICES     (llvmpipe)
E37a AppImage as shipped, vkcube       reported zero accessible devices
E37  this repo, vkcube                 Selected GPU 0: llvmpipe (LLVM 20.1.8)
E40  one file replaced, no variables    Selected GPU 0: llvmpipe (LLVM 20.1.8)
E41  NVIDIA's closed-source libcuda     4096 bytes round-tripped through the GPU
E43a bindings, AppImage as shipped     MIXED: 5 of 6 condvar entry points
E43  bindings, this repo               UNIFORM: 0 of 6
E44  the same, without the wsl dir     cuInit -> 100 CUDA_ERROR_NO_DEVICE
E46  the vendor's own nvidia-smi        GPU 0: NVIDIA GeForce RTX 3050 Ti Laptop
E46a the same binary, no AppImage       env: can't execute .../nvidia-smi
E49  a musl guest, 26 ABI crossings     ABI CROSSING PASSED
E59  every bundled loader classified    8 import dlopen, 0 unclassified
E61  glxgears, no GL shim               couldn't get an RGB, Double-buffered visual
E62  glxgears, with it                  GL_RENDERER = llvmpipe (LLVM 20.1.8)
E63  glprobe, no GL shim                FAILED: no RGB double-buffered visual
E64  glprobe, with it                   readback rgba 64 128 191 255, OK: GL is complete
E65  eglprobe, GL shim only             FAILED: eglGetDisplay -> EGL_NO_DISPLAY
E66  eglprobe, GL + EGL shims           OK: EGL is complete
E67  vkcube with both shims loaded      Selected GPU 0: llvmpipe
E68  the shim pointed at itself         refusing to forward to ourselves
```

E61 through E66 are the ones to read after E40. Every case above them measures
the libc gap; those six measure the other one, and the difference between E62
and E64 is the difference between a shim that makes `glxgears` run and a shim
that replaces a library.

and three more on Debian only, which is where there is a host glibc runtime to
switch to and a hardware GL driver to drive:

```
E51  Design R, then a Vulkan device    OK: 1 physical device
E52  Design R, then the CUDA round trip on the GPU
E53a the AppImage on the d3d12 driver  Error: glXCreateContext failed
E53  the same, plus the conf dirs      GL_RENDERER = D3D12 (NVIDIA RTX 3050 Ti)
```

E40 is the one to look at first. Every other case forces something -- the
feature, the ICD, the loader. E40 replaces `lib/foreign-dlopen.so` inside the
AppDir and runs it with no `CROSS_LIBC_DLOPEN_*` and no `VK_DRIVER_FILES` at all, which
is the only form of the claim that matches what was asked.

### 3.4 Driving it by hand

The suite is the reproducible form, but when you are debugging you want the
pieces. Build the preload on **bullseye** so it only needs old symbols, drop it
into the AppDir, and run against Alpine:

```bash
# in debian:bullseye-slim, with the repo mounted
cd src && make                      # cross-libc-dlopen.so, gl-fwd.so, egl-fwd.so,
                                    # runtime-select

# in alpine:3.22, with AppDir and the built .so mounted
apk add --no-cache mesa-vulkan-swrast vulkan-tools vulkan-loader
export APPDIR=/w/AppDir XDG_RUNTIME_DIR=/tmp/xdg
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
mkdir -p $XDG_RUNTIME_DIR

# A/B: the same command, feature off then on. Never trust a single-sided run.
CROSS_LIBC_DLOPEN=0 \
  "$APPDIR/lib/ld-linux-x86-64.so.2" --library-path "$APPDIR/lib" ./vkprobe

CROSS_LIBC_DLOPEN=1 \
  "$APPDIR/lib/ld-linux-x86-64.so.2" --library-path "$APPDIR/lib" \
  --preload "$APPDIR/lib/foreign-dlopen.so" ./vkprobe
```

> Use `ld.so --preload` rather than `LD_PRELOAD` when a musl binary is anywhere
> in the pipeline (`strace`, `env`). `LD_PRELOAD` applies to those too, and
> musl's loader cannot load a glibc `.so`.

Test programs, all built on a glibc host and run under the bundled loader:

| File | What it does |
|---|---|
| [`tests/icd-harness.c`](../tests/icd-harness.c) | cross-libc load one ICD, resolve `vk_icdGetInstanceProcAddr`, call through it |
| [`tests/vkprobe.c`](../tests/vkprobe.c) | bundled Vulkan loader plus host ICD, `vkCreateInstance` then `vkEnumeratePhysicalDevices`, no window system |
| [`tests/corpus.c`](../tests/corpus.c) | `dlopen` every `.so` in a directory, print OK/FAIL with the reason |
| [`tests/invariants.c`](../tests/invariants.c) | one libc family in `/proc/self/maps`, bundled sonames win |
| [`tests/soak.c`](../tests/soak.c) | N load/unload cycles with RSS, fd and rewritten-copy counts |
| [`tests/verprobe.c`](../tests/verprobe.c) | the version-binding trap as a loadable probe: returns 0 or 22 |
| [`tests/vertrap.c`](../tests/vertrap.c) | the three libc properties `version-compat.c` rests on |
| [`tests/allocprobe.c`](../tests/allocprobe.c) | interpose the allocator family; every counter carries its total |
| [`tests/glprobe.c`](../tests/glprobe.c) | GL past the 33 symbols `glxgears` links, then clears to a known colour and reads the pixel back |
| [`tests/eglprobe.c`](../tests/eglprobe.c) | the same question asked of EGL, surfaceless, with no X server at all |
| [`tests/cudaprobe.c`](../tests/cudaprobe.c) | cross-libc load a closed-source vendor driver, then push bytes to the GPU and read them back |
| [`tests/bindprobe.c`](../tests/bindprobe.c) | walk every loaded object's relocations and report which DEFINITION each one bound |
| [`tests/abi-host.c`](../tests/abi-host.c) | the cross-libc crossings, against [`abi-guest.c`](../tests/abi-guest.c) built by the other libc |

Reaching the GPU by hand needs two flags on the container and one directory on
the library path, none of which is guessable:

```bash
MSYS_NO_PATHCONV=1 "$PODMAN" run --rm \
  --device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro \
  -v "$PWD:/repo:ro" -v "$PWD/.tmp:/w" alpine:3.22 sh -c '
    APPDIR=/w/AppDir; LP=$APPDIR/lib
    CROSS_LIBC_DLOPEN=1 APPDIR=$APPDIR \
      "$LP/ld-linux-x86-64.so.2" --library-path "$LP:/usr/lib/wsl/lib" \
      --preload "$LP/foreign-dlopen.so" \
      /w/build/cudaprobe /usr/lib/wsl/lib/libcuda.so.1'
```

Drop `:/usr/lib/wsl/lib` and it still loads, still resolves every entry point,
and then reports `cuInit -> 100 CUDA_ERROR_NO_DEVICE`. That is E44, and it is
the single most misleading failure in this repository.
