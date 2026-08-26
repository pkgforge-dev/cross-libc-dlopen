## 11. Known unfixed and out of scope

**Case 3, a glibc-built host library loading into a musl process, is out of
scope and not addressed.** The packaging always bundles glibc deliberately,
because musl would lose the proprietary NVIDIA driver. Anyone who needs case 3
should use [pg83/solo](https://github.com/pg83/solo), which solves it with its
own ELF loader (`lib/elf_loader.cpp`, 2707 lines) and a glibc-to-musl ABI bridge
(`lib/glibc_shim.cpp`, 5948 lines).

⚠ **A previous version of this paragraph described solo's CI from reading rather
than from checking, and one of its numbers was wrong.** Verified against solo's
own `.github/workflows/ci.yml` at commit `79451211`: nine jobs on every push and
pull request (Alpine/musl, Fedora/GCC, Ubuntu/Clang, Ubuntu/arm64, a qemu
kernel boot, NixOS/lavapipe, and Termux/bionic on both architectures), plus
`abi_diff`, `secure_test`, `rootfs_smoke`, `pthread_test`, `vulkan_test` and
coverage upload. The corpus manifest `tst/corpus_x86_64.json` lists **1176
packages** (aarch64: 1172); the "2100 objects" figure previously stated here is
not what that file says, and the object count after unpacking was not measured.
The full sweep is in
[`../history/references/solo-findings.md`](../history/references/solo-findings.md).

⛔ **A musl object cannot allocate and initialise its own `pthread_mutex_t` in
a glibc process on aarch64, and nothing here fixes it.** musl's is 40 bytes
there and glibc's is 48, so the object allocates 40 and the `pthread_mutex_init`
it reaches writes 48. ⚠ No crossing is involved: the overflow is inside the
musl object, on its own allocation, and it happens because the loader did
exactly what it is supposed to do. It is measured, it is architecture-specific,
and x86-64 does not have it because both are 40 there. Section 9.18 has the
transcript and the size table. This is the shape the whole approach cannot
address: the loader can make every reference resolve to one libc, and it cannot
change a size the object compiled in.

Also not delivered: NVIDIA's glibc-only userspace on a musl process, static musl
binaries with GPU access, bridging manylinux wheels into Alpine, and distroless
containers reaching host NSS or PAM.

Two designs were evaluated on paper and both rejected, with evidence, in
[`../rejected-designs.md`](../rejected-designs.md).
`dlmopen` into a private namespace is impossible (E9 measures it failing
identically to plain `dlopen`). A private ELF loader costs about 2700 lines,
still needs a shim, and buys isolation for a collision surface measured at three
sonames.

---

---

[REPORT index](README.md) | [previous](10-measured-versus-assumed.md) | [next](12-residual-risk.md)
