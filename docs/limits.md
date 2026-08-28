# What it cannot do

Every row names the measurement behind it, or says plainly that there is none.

⭐ **Every row stops at the missing capability and claims nothing about the
design space.** That rule, and the session it cost this project, are in
[`conventions/prose.md`](conventions/prose.md).

Open items with a route to closing them are in
[`docs/todo/blocked.md`](todo/blocked.md). This page is what a *user* needs.

---

## Measured, and not fixable here

| limit | the measurement |
|---|---|
| **Two glibc-vs-musl struct hazards are live** | `regoff_t` is 4 bytes on glibc and 8 on musl, so a musl object reading back a glibc-filled `regmatch_t[]` reads at its own stride; the `FTW_*` constants are off by one, so an `nftw` walk classifies entries wrongly. E50, [`report/07-closed-source-driver-and-abi.md`](report/07-closed-source-driver-and-abi.md) section 7.4. An offset compiled into an object is not reachable from a preload |
| **Two further hazards are argued, not measured** | `ucontext_t` and `O_LARGEFILE`. Nothing here crosses them, so there is no crossing to test. They stay labelled rather than counted |
| **Entry points the host does not implement stay unimplemented** | on one measured host, 1097 of the GL entry points are extensions glvnd knows the names of and Mesa has no code for. What this project does is make the absent case **observable**: a call to one produces a line naming it, not a silent zero (E72, E73). Making Mesa implement them is not this project's work |
| **A host with no EGL implementation cannot be given one** | Mesa 8.0.4 ships EGL 1.4 and `eglInitialize` fails there even with the right directory. Measured natively, with no bundle in the process at all: 16.04's EGL fails the same probe with nothing of this project loaded (E79) |
| **A GTK4 GL renderer needs an OpenGL 3.2 host context; a host whose GL stack cannot provide one falls back to Cairo and GL widgets report "GL disabled"** | GTK4's GL renderer asks for a minimum of OpenGL 3.2 (or GLES 2.0). Measured on `ubuntu:14.04` (Mesa 10.1): the renderer could not realize a GL context and GTK4 fell back to `GskCairoRenderer`, with the OpenGLArea demo reporting GL disabled. On `ubuntu:16.04` (Mesa 18.0.5), on softpipe (GL 3.3) and on Mesa 26.1.4 the same AppImage rendered via GL, so the ceiling is the host's context, not a missing extension. A shim forwards an entry point; it cannot manufacture a GL context the host's Mesa will not create |

## Not measured here, and stated as such

| limit | why |
|---|---|
| **DRM-native `radv` and `radeonsi` drivers** | the primary measuring machine publishes no `/dev/dri`. Intel `anv` is measured on an external Alpine host in [`report/09-the-second-boundary.md`](report/09-the-second-boundary.md) section 9.19; no measured host here provides the AMD drivers |
| **aarch64 on real silicon** | the trampolines assemble and **run under qemu-user** (E76, E76b). qemu emulates the instructions, not a memory model. CI's `ubuntu-24.04-arm` runner is what closes this, and it is the one place CI is stronger than the machine this was built on |
| **NVIDIA's closed-source stack in CI** | nothing stands in for it. The local result, 4096 bytes round-tripped through an RTX 3050 Ti and verified (E41), is in [`report/07-closed-source-driver-and-abi.md`](report/07-closed-source-driver-and-abi.md) section 7.1 |

---

## Static binaries: three cases, not one

⚠ **"Static binaries cannot `dlopen`" is the wrong answer.** It is close enough
to true to be repeated, and wrong in the way that matters here.

| case | status |
|---|---|
| **Static musl** | `dlopen` is present and is a stub: it fails, always. This is the one case genuinely out of scope, and nothing this project does can change it. ⚠ Confirm against the musl version in front of you rather than against this sentence |
| **Static glibc** | `dlopen` **works**, and glibc warns at link time that doing so "requires at runtime the shared libraries from the glibc version used for linking". ⭐ That warning is a description of this project's entire subject. Not out of scope: it is the case with the sharpest version constraint of all. ⚠ **The real blocker is more likely the preload path than `dlopen`**: a fully static binary has no `LD_PRELOAD` mechanism, because there is no dynamic loader to honour it |
| **Mostly static, dynamically linked against libc only** | the common shape for a portable release binary. Squarely in scope, and the easiest of the three |

⛔ **UNVERIFIED, all three.** No measurement of any of them has been taken in
this repository. They are written down as three distinct questions, with the
reasoning that distinguishes them, and **not** as three answers.
[`docs/todo/`](todo/INDEX.md) carries them as work. An "N/A" here without a
measurement behind it would be the same mistake [`report/10-measured-versus-assumed.md`](report/10-measured-versus-assumed.md) section 10's
last entry is about.
