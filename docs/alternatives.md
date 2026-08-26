# alternatives.md

Other answers to "my binary needs the host's GPU driver and the libcs do not
match", and which one fits your position. The GPU driver is always the host's,
always a shared object, and almost always built against glibc. Everything below
is a different answer to that one fact.

---

## The four positions

| | what you ship | GPU on a foreign-libc host | what it costs you |
|---|---|---|---|
| **A static binary** | one musl-static file, no dependencies | ⛔ **no.** A fully static musl binary cannot `dlopen` the host's glibc driver at all | you must be able to build your whole application musl-static |
| **A static binary plus [`solo`](https://github.com/pg83/solo)** | the same file, plus solo's `libdlfcn.a` | **yes**, through solo's own ELF loader and glibc-ABI bridge | the same musl-static build, and musl's allocator and threading rather than glibc's |
| **A plain dynamic bundle** | your app and its glibc, dynamically linked | ⛔ **no**, on two distinct hosts: one whose driver is a different libc family, and one that ships no glvnd vendor library | nothing. It works everywhere except the GPU |
| **A dynamic bundle plus this** | the same bundle, plus three preloaded objects | **yes**, on both | one `.preload` entry, or one `LD_PRELOAD`. Nothing about your build changes |

⭐ **The precondition decides it, not the mechanism.** solo's own README asks
you to link its archive into a musl-static application, built with its
companion build system. That is a coherent design and it is a rebuild of your
entire dependency graph. This project's precondition is that you already have a
dynamically linked process, which is what a distribution package, a container
image or an AppImage gives you.

So the two are not really competitors. **solo completes a static binary; this
completes a dynamic one.**

---

## The mechanisms

| | solo | this |
|---|---|---|
| the process | static musl, whose image solo owns entirely | bundled glibc, inside somebody else's process |
| the loader | replaced, with its own ELF loader, symbol-version matching and `ld.so.cache` reader | the host's, untouched. Only `dlopen` is interposed |
| the libc bridge | hand-written, and large | generated from measured symbol inventories, plus a version-trap forwarder set |
| gap 2, the missing vendor library | not addressed | ⭐ the other half of this project |

⭐ **Gap 2 is the one most people actually hit, and only one of the two
addresses it.** A host whose Mesa was built without glvnd ships no
`libGLX_<vendor>.so.0`, and no amount of libc bridging carries a file that does
not exist. If your symptom is `couldn't get an RGB, Double-buffered visual`,
that is this gap. solo does not meet it, because a static binary bringing its
own stack never goes looking for a vendor library the host was supposed to
ship. [`overview.md`](overview.md) has both gaps in full.

---

## The honest verdict

**If you are starting fresh and can build musl-static, solo is the more mature
choice.** Its ABI bridge covers cases this one records in
[`limits.md`](limits.md), and it is tested across more host classes than this
project has ever run on. That is the answer even though it is not this
project's.

**If you already ship a dynamically linked bundle, this is the only one of the
two that applies.** Rebuilding a working glibc bundle around a different libc
to fix one subsystem is a large change, and it is the change solo's approach
requires. A preload is not.

⚠ **Not measured here:** the runtime cost of the musl-static route. musl's
allocator and thread primitives are documented as trading throughput for size
and simplicity, and this project has taken no measurement of either
implementation. Treat it as a trade-off to check for your workload, not as a
number from this repository.

The full sweep of solo's code, at the commit it was read at, is in
[`history/references/solo-findings.md`](history/references/solo-findings.md).
What was found in it that this project could adopt is in
[`history/references/solo-usable.md`](history/references/solo-usable.md).
