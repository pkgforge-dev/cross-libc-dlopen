# The environment the measurements were taken in

Every number in [`REPORT.md`](REPORT.md) came from this machine unless the
text says otherwise. It is stated so a result that differs elsewhere can be
attributed rather than argued about.

## 2. Environment

Everything runs in throwaway containers. No GPU is needed for any mandatory
test; Mesa's software rasterisers (**lavapipe** for Vulkan, **llvmpipe** for GL)
exercise the identical `dlopen` path, and the cases that do need hardware are
SKIPPED by name without it.

```
podman 5.8.6 at %LOCALAPPDATA%\Programs\Podman\podman.exe   (NOT on PATH)
podman machine: podman-machine-default, a running WSL2 Fedora 44 VM
Python 3.13 on PATH as `py -3`
```

**There is a GPU, and reaching it is not obvious.** This machine has a discrete
NVIDIA RTX 3050 Ti Laptop (driver 580.97) and an Intel Iris Xe. WSL2 exposes
both through `/dev/dxg` paravirtualisation and bind-mounts the driver userspace
from Windows at `/usr/lib/wsl`; it publishes **no `/dev/dri` at all**, so `radv`,
`anv` and `radeonsi` are out regardless. Two flags put a container on the
silicon:

```bash
MSYS_NO_PATHCONV=1 "$PODMAN" run --rm \
  --device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro \
  debian:trixie-slim sh -c 'LD_LIBRARY_PATH=/usr/lib/wsl/lib \
      /usr/lib/wsl/lib/nvidia-smi -L'
# GPU 0: NVIDIA GeForce RTX 3050 Ti Laptop GPU (UUID: GPU-df849629-...)
```

For **graphics**, the route is Mesa's `d3d12` Gallium driver, which needs no DRM
node and which Debian packages as `dri/d3d12_dri.so`:

```bash
GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
  xvfb-run -a -s '-screen 0 1024x768x24 +extension GLX +render' glxgears -info
# GL_RENDERER = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)   115 FPS
```

`MESA_D3D12_DEFAULT_ADAPTER_NAME` is the only way to choose between the two
GPUs; without it you get the Intel one, which is still hardware and still a
valid result, just not the one you probably meant.

`scripts/wsl-ephemeral.ps1` creates throwaway WSL2 distros from any OCI image
if you need a real init-less VM rather than a container.

**Bind mounts from Git Bash need `MSYS_NO_PATHCONV=1`**, otherwise Git Bash
mangles the container-side path:

```bash
MSYS_NO_PATHCONV=1 "$PODMAN" run --rm -v "$PWD:/repo:ro" alpine:3.22 sh -c '...'
```

`.tmp/` is gitignored scratch. `appimage.ps1` caches the demo AppImage and the
extracted AppDir there, so the second run is much faster than the first.
