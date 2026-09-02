## 1. Summary

| Goal | Status |
|---|---|
| A host GPU driver built against a **newer glibc** loads into a process carrying an older bundled glibc | **Achieved.** Two mechanisms: the generated shim (E5) and the host-runtime switch (E12, no shim at all). The selector picks correctly on 8 of 8 distros |
| A **musl-built** host driver loads into that same glibc process **and renders** | **Achieved.** On Alpine 3.22, the demo AppImage's bundled glibc 2.44 drives Alpine's musl-built lavapipe: `vkEnumeratePhysicalDevices` returns one device and `vkcube` renders (E32, E37). Exactly one libc family is mapped (E35). 60 s of continuous rendering with RSS, fds and threads flat. See section 6 |
| A **closed-source** host driver does the same, on real silicon | **Achieved, and it never needed the fix.** NVIDIA's `libcuda.so.1` loads under the bundled glibc on Alpine and round-trips 4096 bytes through an RTX 3050 Ti (E41), and so does the control, because a vendor ships against a `GLIBC_2.2.5` floor on purpose. What the vendor stack DID need is uniform version binding (E43a/E43). Section 7.1 |
| Rendering on an actual GPU rather than a software rasteriser | **Achieved for OpenGL.** `GL_RENDERER = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)` at 101-121 FPS through the AppImage with no file changed (E53), via Mesa's d3d12 Gallium driver, which needs no DRM render node. Vulkan is still lavapipe: `dzn` is not packaged. Section 7.5 |
| The cross-libc ABI microtests, T1.3-T1.7 | **Written and passing.** 26 crossings hold with a musl guest; of the six struct hazards, two are live and named and four are benign, measured rather than assumed. Section 7.4 |

| Completion criterion | Status |
|---|---|
| Both goals demonstrated by a test that fails before and passes after | **Yes.** Goal 1: E5, E12. Goal 2: E22/E23 for the mechanism, E30/E32 and E37a/E37 for the end-to-end |
| The evidence harness still reports all predictions held | **Yes, 63/63** on x86-64 and **60/60** on aarch64, up from 22/22. The AppImage suite adds 45 on a glvnd glibc host, 40 on musl, 26 on each of two pre-glvnd glibc hosts and 7 on a real-application stage, with every unrunnable case SKIPPED by the capability it lacks |
| No host file modified, verified by checksum | **Yes.** T4.3, identical sha256 before and after |
| Bundled libraries still win, verified via `dladdr` | **Yes.** T4.2, all resolved under `$APPDIR` |
| A forward-compatibility story that does not depend on foresight | **Yes.** Host-runtime selection for the unenumerable gap, a generated shim for the enumerable one, and a build-time audit (E26) for the version traps |
| A report separating measured from assumed | this document |

The one thing this report previously got wrong is worth stating plainly, because
it was the central claim: **the rendering failure was blamed on glibc-vs-musl
ABI differences, and it was not that.** Removing an object's symbol version
requirements is by itself enough to break it, on one libc, with no musl and no
Vulkan anywhere in the process. Section 6.2 is the measurement.

---

---

[REPORT index](README.md) | [next](02-environment.md)
