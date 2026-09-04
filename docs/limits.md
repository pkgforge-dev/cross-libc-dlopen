# What it cannot do

This page is for a *user*: what the project will not fix for you, and why.
Every row is measured, or says plainly that it is not.

The general rule is one sentence. **The host's graphics stack is the ceiling.**
This project lets a bundled application reach that ceiling across a libc
boundary. It does not raise the ceiling. A feature the host does not have stays
unavailable, no matter how well the libc gap is bridged.

Open items with a route to closing them are in
[`docs/todo/blocked.md`](todo/blocked.md).

---

## What is measured, and not fixable here

| limit | why it is not fixable |
|---|---|
| **Two glibc-vs-musl struct layouts disagree** | `regoff_t` is 4 bytes on glibc and 8 on musl, so a musl object reading a glibc-filled `regmatch_t[]` reads at its own stride. The `FTW_*` constants are off by one, so an `nftw` walk classifies entries wrongly. The offset is compiled into the object, so no preload can reach it. E50, [`report/07-closed-source-driver-and-abi.md`](report/07-closed-source-driver-and-abi.md) section 7.4 |
| **Two more are suspected but unproven** | `ucontext_t` and `O_LARGEFILE`. Nothing here crosses them, so there is nothing to test them with. They stay labelled as suspected, not counted as broken |
| **Entry points the host Mesa does not implement stay unimplemented** | on one measured host, 1097 GL entry points are extensions glvnd knows by name and Mesa has no code for. What the project does is make the absence *visible*: a call produces a line naming it, not a silent zero (E72, E73). Making Mesa implement them is somebody else's work |
| **A host with no EGL implementation cannot be given one** | a host whose Mesa predates a working EGL, like Ubuntu 16.04, fails the same probe with nothing of this project loaded (E79). The shim is reproducing the host, not failing |
| **GTK4 needs an OpenGL 3.2 host context** | GTK4's GL renderer needs OpenGL 3.2 (or GLES 2.0), and it works wherever one exists: Ubuntu 16.04, softpipe at GL 3.3, Mesa 26.1.4. The one failure seen is Ubuntu 14.04's Mesa 10.1, which cannot create any GL context behind a modern glvnd dispatcher. There GTK4 still runs, but falls back to Cairo and GL-using widgets report "GL disabled". The preload cannot manufacture a context Mesa will not create |

## What is not measured, and stated as such

| limit | why it is unmeasured |
|---|---|
| **DRM-native `radv` and `radeonsi` drivers** | the primary measuring machine has no `/dev/dri`. Intel `anv` is measured on an external Alpine host in [`report/09-the-second-boundary.md`](report/09-the-second-boundary.md) section 9.19; no measured host here provides the AMD drivers |
| **aarch64 on real silicon** | the trampolines assemble and run under `qemu-user` (E76, E76b), which emulates instructions, not a memory model. CI's `ubuntu-24.04-arm` runner is the one place CI is stronger than the machine this was built on |
| **riscv64, ppc64, ppc64le and loongarch64 beyond the build** | the trampolines and the resolver run under `qemu-user` against the Debian cross sysroots, and every artefact builds and passes `scripts/verify-artifacts.sh` on each. No silicon, no runner, and no host Mesa has been behind the shims on any of the four. The evidence suite cannot run for them either: upstream publishes no demo AppImage for these architectures. [`report/10-measured-versus-assumed.md`](report/10-measured-versus-assumed.md) |
| **NVIDIA's closed-source stack in CI** | nothing stands in for it. The local result, 4096 bytes round-tripped through an RTX 3050 Ti and verified (E41), is in [`report/07-closed-source-driver-and-abi.md`](report/07-closed-source-driver-and-abi.md) section 7.1 |

---

## Static binaries: three cases, not one

⚠ **"Static binaries cannot `dlopen`" is the wrong answer.** It is close enough
to true to be repeated, and wrong in the way that matters here.

| case | status |
|---|---|
| **Static musl** | `dlopen` is a stub: it fails, always. This is the one case genuinely out of scope. ⚠ Confirm against the musl version in front of you rather than against this sentence |
| **Static glibc** | `dlopen` **works**, and glibc warns at link time that doing so "requires at runtime the shared libraries from the glibc version used for linking". ⭐ That warning is a description of this project's entire subject. ⚠ **The real blocker is more likely the preload path than `dlopen`**: a fully static binary has no `LD_PRELOAD` mechanism, because there is no dynamic loader to honour it |
| **Mostly static, dynamically linked against libc only** | the common shape for a portable release binary. Squarely in scope, and the easiest of the three |

⛔ **All three are UNVERIFIED.** No measurement of any of them has been taken in
this repository. They are written down as three distinct questions, with the
reasoning that distinguishes them, and **not** as three answers.
[`docs/todo/`](todo/INDEX.md) carries them as work.