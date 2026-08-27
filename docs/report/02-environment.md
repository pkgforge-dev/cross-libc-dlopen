## 2. Environment reached

**Highest tier reached: Tier 5**, on hardware, for OpenGL, compute and Vulkan.
All Tier 4 invariants run. The local Tier 3 end-to-end runs use software
Vulkan under `xvfb`; section 9.19 records the external Intel hardware run.

```
$ uname -srm                     # inside every test container
Linux 7.2.0-WSL2-STABLE x86_64

podman version 5.8.6             (WSL2 Fedora 44 machine)
Python 3.13                      (host, for the Tier-0 tooling)
```

| Image | libc | Role |
|---|---|---|
| `alpine:3.22` | musl 1.2.5 | the musl host, software Vulkan |
| `debian:bullseye-slim` | glibc 2.31 | "an AppImage bundling an older glibc", and the build host |
| `debian:trixie-slim` | glibc 2.41 | the newer-glibc build host |
| `ubuntu:20.04` | glibc 2.31 | no-regression check |
| `rockylinux:9` | glibc 2.35 | selector matrix |
| `fedora:44` | glibc 2.43 | selector matrix |
| `opensuse/tumbleweed` | glibc 2.43 | selector matrix |
| `archlinux:latest` | glibc 2.44 | selector matrix, newest released glibc |
| `ubuntu:14.04` | glibc 2.19 | pre-glvnd glibc host, Mesa 10.1.3, no Vulkan at all |
| `ubuntu:16.04` | glibc 2.23 | pre-glvnd glibc host, Mesa 18.0.5, no Vulkan at all |

One external hardware run on 2026-08-27 adds the real VA-API result in
section 9.19. It used an x86-64 Wayland session on Alpine
`3.25.0_alpha20260805`, with these host packages:

| package | version |
|---|---|
| `intel-media-driver` | `26.2.1-r0` |
| `intel-gmmlib` | `22.10.0-r0` |
| `libva` | `2.23.0-r0` |
| Mesa | `26.1.6-r0` |

The run forced the `iHD` VA-API driver. The exact Intel GPU model was not
captured and remains UNVERIFIED.

⚠ The last two are served from `archive.ubuntu.com` at the DEFAULT path,
because they are still inside their ESM window, and they are **not** on
`old-releases.ubuntu.com`, which as of 2026-08 carries neither. The
`sources.list` rewrite every guide prescribes is what breaks them; what has to
go is the image's own ESM source, which needs credentials and makes apt fail
the whole update and then report every package as "unable to locate".

Software rendering is used for every Vulkan result and is named in each one:
Mesa **lavapipe** and **llvmpipe** (LLVM 20.1.8, 256 bits), pinned with
`VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json` so a half-working
host GPU could not silently take over.

Two GPUs are reachable and are used where a case says so: an NVIDIA GeForce
RTX 3050 Ti Laptop and an Intel Iris Xe, both through `/dev/dxg`
paravirtualisation with the vendor userspace bind-mounted from
`/usr/lib/wsl`. There is no `/dev/dri` on this machine at all, so `radv`, `anv`
and `radeonsi` cannot initialise; `d3d12` and CUDA do not need one. Cases that
require the device are SKIPPED with that capability named on a machine without
it, and the suite still passes.

The host driver is sane natively, so every downstream result is interpretable:

```
$ vulkaninfo --summary        # Alpine 3.22, native musl
        deviceName         = llvmpipe (LLVM 20.1.8, 256 bits)
        driverName         = llvmpipe
```

---

---

[REPORT index](README.md) | [previous](01-summary.md) | [next](03-defects-found-by-measurement.md)
