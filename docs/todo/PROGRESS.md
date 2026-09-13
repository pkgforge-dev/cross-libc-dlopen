# PROGRESS

⭐ **Read this first, every session.** [`INDEX.md`](INDEX.md) carries the list; this carries the order and the baseline.

⚠ **Rewritten every session. It carries no history.** That is [`../history/`](../history/README.md)'s job.

---

## Where the work is right now

[v0.2.5](https://github.com/pkgforge-dev/cross-libc-dlopen/releases/tag/v0.2.5) is
published. The aarch64, riscv64 and loongarch64 artefacts of every release so
far carry the defect below; there is no release yet without it.

| workflow | latest on `main` |
|---|---|
| `gates` | ✅ |
| `secret-sweep` | ✅ |
| `release` | ✅ on `v0.2.5` |

**This branch fixes issue #37 and needs a release once merged.** The next
consumer (Helium, Brave, Chrome AppImages via quick-sharun) is crashing on
aarch64 CI today.

---

## ⛔ The work order

### 1. `__stack_chk_guard` must not be defined where the loader owns it

⭐ **This is the session's work, on branch `fix/loader-owned-exports`.**

The generated shim emitted `__stack_chk_guard` as a function stub, because
the generator consulted the x86-64 target inventory for its type and the name
is musl-only there. On aarch64, riscv64 and loongarch64 the dynamic loader
exports that name as the process-wide stack canary, and an unversioned
preload definition wins every lookup in the process, `libc.so.6`'s own
included. Chromium's GPU process died with SIGSEGV under the preload with the
feature switch off; x86-64 and ppc64le were never affected, because their
loaders keep the canary in thread storage and never export the name.
[../report/03](../report/03-defects-found-by-measurement.md) 3.7 has the
whole chain with the measurement table.

Three layers, all on this branch:

- the generator excludes the name on the three architectures whose loader
  exports it, emits it as zeroed data of the real size everywhere else, and
  decides FUNC versus OBJECT from the merged kind table rather than the x86-64
  target's. `src/forward-shim.c` and the manifest are regenerated.
- `scripts/verify-artifacts.sh` refuses any build whose preload exports a
  name the target's own libc family also exports, beyond `dlopen` and
  `version-compat.c`'s forwarders. `CLD_SYSROOT` names the target sysroot for
  a verification outside a build; that is how its refusal was proven on this
  x86-64 machine against the real bullseye arm64 cross libc.
- **E102** is the suite's case, run on both rows of the evidence table. Its
  logic was proven against the real floor cross libc on this machine: the
  released v0.2.5 aarch64 object makes it report `__stack_chk_guard` and the
  fixed one reports nothing. The row on the ARM runner itself is the PR's CI
  run, which is where E101's aarch64 number was measured too.

The suite total moved by one on both rows with E102. Report 08 owns the new
numbers, and every one-home record moved with it: `gates.yml`,
`scripts/verify-gates.sh` and that script's probe string.

Measured locally besides the suite: the fixed x86-64 build exports the same
140 names as before, with seven musl-object symbols re-typed from FUNC stubs
to data of their real sizes (`___environ`, `__optpos`, `__optreset`,
`__stack_chk_guard`, `_ns_flagdata`, `h_errno`, `optreset`); the planted
defect, the released v0.2.5 aarch64 object, makes both the gate and E102's
logic refuse naming the symbol; the gate's `defined_names` was caught reading
only the first member of the target list, which measured a whole pass against
`libc.so.6` alone and reported the loader's canary absent.

And measured on real silicon, in a consumer's CI rather than this
repository's: an unmodified Helium AppImage build whose only change is
compiling this branch and dropping the object into `AppDir/lib/sharun-preload`
passes its packaged `--test` on aarch64 and x86-64, with zero GPU-process
SIGSEGVs in both the `CROSS_LIBC_DLOPEN=0` control arm and the default arm,
where the released object had six in each. The runs are linked from the pull
request, because a fork's logs are not files this repository can cite.

### 2. What is still open

Nothing from this session. The open list is [`INDEX.md`](INDEX.md) and the
work order lives nowhere else.

---

## ⚠ What a new session should distrust

- **The aarch64 and riscv64 and loongarch64 rows of `build` in CI are the
  only builds that exercise the new gate against a real target sysroot.** A
  green row means the artefact exports no name that target's libc family has;
  a machine without that libc installed now REFUSES the build rather than
  reporting the property unverified, so the three architectures with no
  runner cannot ship on a check that measured nothing.
- **`forward-shim.c` is one file compiled for every architecture, and its
  arch-conditioned emission is the only per-architecture behaviour in it.**
  The `#if` guard spells the three excluded architectures with the same
  macros `src/cross-libc-dlopen.c` uses for its triplets. A new architecture
  added to the build emits the symbol by default; the gate then refuses the
  build if that architecture's loader exports the name, which is the intended
  failure rather than a shipped crash.
- **The wide appimage suite has failed at its extraction step since late
  August**, on both rows, for reasons unrelated to this branch. Its aarch64
  row is the only real-driver run this repository has, and it is not running.
  Fixing that is not this branch's work.
- **`__stack_chk_guard` is load-bearing on x86-64 and ppc64le**, where musl
  guests bind it by name. Removing it entirely rather than per architecture
  would turn a working musl load into an unresolved strong symbol at `dlopen`
  time. E49 covers that path on x86-64 and still passes.
