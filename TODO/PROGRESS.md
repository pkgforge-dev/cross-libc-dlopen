# PROGRESS

⭐ **Read this first, every session.** It is the only file that carries a work
order. [`INDEX.md`](INDEX.md) carries the list; this carries the order and the
baseline.

⚠ **Rewritten every session. It carries no history** -- that is
[`../HISTORY/`](../HISTORY/README.md)'s job.

---

## Where the work is right now

⛔ **Everything below is on branch `aarch64-real-and-release`, in
[pull request #8](https://github.com/pkgforge-dev/cross-libc-dlopen/pull/8).**
Its body was rewritten to match the tree. All ten required checks are green;
it is BLOCKED only on an approving code-owner review, which branch protection
requires on purpose.

| suite | command | state |
|---|---|---|
| evidence table, x86-64 | `sh scripts/run-evidence.sh` | exit 0, every prediction held |
| evidence table, aarch64 | the same, on `ubuntu-24.04-arm` | exit 0, three cases SKIP by name |
| AppImage suite | `sh scripts/run-appimage.sh` | ⚠ **completes on both architectures for the first time.** Mismatches remain and they are findings, below |
| build, all four | `sh scripts/build.sh --arch both` and again `--portable` | exit 0 |
| the gates, planted | `sh scripts/verify-gates.sh` | 8 proven, 0 not |
| the documents | `sh scripts/check-drift.sh` | exit 0, six sections |

⛔ **Totals live in [`../docs/REPORT.md`](../docs/REPORT.md)**, not here. Do not
copy one into this file: both are on the one-home list and a second copy turns
the gate red, which is exactly how commit `f6d126e` broke the branch.

---

## ⛔ The work order

### 1. The A/B's control arm no longer contrasts. This needs a decision

⭐ **Start here. It is the only item that changes what the project claims.**

Upstream adopted this project. The demo AppImage's `lib/foreign-dlopen.so` is
gone, `lib/cross-libc-dlopen.so` is in its place, and it is a build of this
project. So the "as shipped" arm of the A/B is no longer upstream's naive shim.

E30 and E37a are the controls for that arm, and they are what make the patched
arm a measurement rather than a coincidence. Both now MISMATCH, because both
arms work. `docs/REPORT.md` 9.17 has the output.

⚠ **Their log lines say `predicted=OK` and that is about the exit status, not
the verdict.** What they assert is the needle, and the needle is the complaint:
`NO-DEVICES` for E30 and `zero accessible devices` for E37a. A MISMATCH there
means the as-shipped arm found a device.

⛔ **Do not flip the predictions.** A control that has stopped contrasting has
stopped measuring, and rewriting it to expect success converts two controls
into two cases that pass whatever the shim does.

⚠ The honest control for "the feature is absent" is an AppDir with **no**
dispatcher in `.preload`, not one carrying somebody else's. Adopting that
changes what the suite claims about upstream, which is why it was left for a
decision rather than taken.

### 2. E50's aarch64 hazard count, which is now measurable and unmeasured

**E49 is diagnosed and fixed.** It aborted with SIGABRT on every aarch64 host
stage, and the cause is a real limitation rather than a harness fault: musl's
`pthread_mutex_t` is 40 bytes on aarch64 and glibc's is 48, so a musl object
that allocates one with its own `sizeof` and calls `pthread_mutex_init` gets
glibc's init writing 48 bytes into 40. ⚠ No crossing is involved. The probe
declines that call now and reports it as a live hazard. `docs/REPORT.md` 9.18
and section 11.

**E50 is the open half.** It requires exactly **two** live hazards, that is an
x86-64 number, and aarch64's is not established. ⛔ Its earlier zero was never
a finding: the count came from a process that had already aborted. With the
guard in place the scan completes, so the next run states a real number.
⭐ Take that number and decide whether the assertion should become
architecture-aware the way E22's condvar probe is. **Do not pin a guess.**

### 3. The pin is a maintained act now. Expect it to go stale again

Both AppImages are pinned by sha256 against a **mutable** `demo` tag, and the
assets were replaced twice inside two minutes. ⛔ There is no immutable release
to pin to: the upstream and the fork publish one release each and both are
tagged `demo`. `docs/REPORT.md` 9.15 has the policy and the reasoning.

When it refuses, read which of the three cases it names: the pin is stale, the
download is wrong, or neither matches. They call for different things.

⚠ `gtk4-demo` comes from `pkgforge-dev/Anylinux-AppImages`, the upstream. The
demo AppImage comes from Samueru-sama's fork and **cannot move**, because
`host-drivers` appears 0 times in the upstream's code and its
`vkcube+glxgears-demo-*` is the build that bundles its own drivers.

### 4. T-12 is answered for one half and unanswerable for the other

The table is in T-12's entry, both runners. ⭐ Every case that ends on its own
is far under its timeout: the slowest is 11 seconds against a 25-second floor
and the rest are at or below one second. The fear the entry was opened on is
not in the data.

⚠ **E61 and E62 measure 30 against a configured 30, and that is not a margin
of zero.** A GL binary never exits on its own, so the timeout is how those two
END. ⛔ Do not raise them on that reading. What stays open is that the
instrumentation cannot tell "ran to its timeout on purpose" from "was killed
before finishing", because both look identical.

### 5. T-10, T-11, T-16

T-10's entry now carries which gates have been seen to refuse and where, and
⭐ four of them were not planted: they went red on a runner against a real
defect, which is stronger than a plant because nobody chose the shape of the
failure. ⛔ Four are still unproven and the entry names them: the endings gate,
which `.gitattributes` makes unplantable from the working tree; the two
`generated` steps; and the artefact verifier's floor rule. Those need a runner
and a deliberate push.

⛔ **One guard remains unproven and cannot be proven without publishing:**
`release.yml` refuses a tag whose commit is not an ancestor of the default
branch. `package-release.sh`'s two were planted this session and both refuse.

T-11 and T-16's cheaper half were not started. T-16's is a `glprobe` change,
and it can only be verified by a GL-capable suite run.

### 6. Then the release

Nothing is published. The build and package path is proven by pull request #8;
the publish path cannot be until `release.yml` is on the default branch. After
merge, push a `v*` tag and watch it.

⚠ **Publishing was outside the last session's permissions**, so the tag was
not pushed even though everything up to it is ready. Check the permissions
block before assuming it is yours to do.

---

## What this session did

Every claim below has its measurement in `docs/REPORT.md` 9.14 through 9.17.

**Three deep review passes**, each with a different question.

*Pass 1, can every guard added here refuse?* The dash ratchet was recorded as
having failed to fire. It had not: the refusal condition was `count > pin`,
nothing ever lowered the pin, and the tree had drifted eight under, so the
planted dash landed inside the slack. The pin is exact now and a fall refuses
too. It also counted the `--` that the prose rule exempts inside a code block,
which made the section recording the fix unwritable. The cited-path check
could not see a path cited in front of a command, and so never noticed that
`conventions/prose.md` named a ratchet script that has never existed.

*Pass 2, what did this branch stop measuring?* The ARM runner was added saying
qemu "emulates the instructions and not a memory model", and section P went on
running the aarch64 trampolines under qemu **on aarch64 silicon**. It picks its
vehicle from the host now and prints it. The marker was removed and four
documents went on calling it load-bearing.

*Pass 3, does every claim hold when the command is run?* T-13's
"print a MISMATCH in full" was in one harness and not the other, and it was
found by the failure it describes. The corpus cases were the same shape a
third time, reporting a zero total with the reason in a discarded stderr.
`INDEX.md` listed two entries as open that declare themselves DONE.

**Three new checks, each planted and seen to refuse.** The dash ratchet in
`verify-gates.sh`; the two orchestrators pinning the same bytes; every
`INDEX.md` row against its entry's declared status.

**The AppImage suite completes**, having never done so before. Getting there
meant re-pinning against a mutable tag, moving `gtk4-demo` to the true
upstream, and teaching the suite to read the dispatcher slot out of the AppDir
rather than spelling it.

⭐ **And completing it found a real limitation nothing else could have.** On
aarch64 a musl object cannot allocate and initialise its own `pthread_mutex_t`
in a glibc process: 40 bytes allocated, 48 written, no crossing involved. It
needed real ARM silicon, three chained reporting defects fixed before it was
even legible, and one wrong fix before the right one. `docs/REPORT.md` 9.18.

**`tests/bindprobe.c` builds on aarch64.**

**T-12 answered**, and **T-10's entry now says which gates have been seen to
refuse and where**, including four that were never planted because they went
red on a runner against a real defect.

---

## ⚠ What a new session should distrust

- **The `.preload` baseline is DERIVED, not shipped.** The AppImage ships this
  project's own forwarding shims in its `.preload`, and restoring that list
  would make every absence case measure a presence. `41-extract.sh` prints what
  it drops on every extraction. If that line disappears, look at it.
- **`ground-truth.md`'s inventory carries a verdict column now.** Two rows are
  UNVERIFIED and say why. Do not quietly re-attach them to the new binary.
- **The tracker is evidence, not instruction.** Pull request #9's premise, that
  `-fcf-protection=full` breaks aarch64, is true of `main` and already fixed on
  this branch; what remains of it is a policy question about the default.
- **A guard that has never been seen to refuse is a guard nobody knows works.**
  Three were found decorative or unarmed this session and every one of them
  looked fine.
