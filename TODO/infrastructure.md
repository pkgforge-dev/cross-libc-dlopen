# Infrastructure

Build, CI and orchestration.

---

## T-10 Prove every CI gate can fail

- **Source.** The port brief, review pass 2.
- **Category** infrastructure · **Priority** high · **Effort** low ·
  **Status** open
- **Problem.** ⭐ **A gate never seen to refuse is a gate nobody knows works.**
  The workflows in [`../.github/workflows/`](../.github/workflows/) were written
  and reasoned about; only some of them have been watched to go red.
- **Premise.** Measured locally for three of them -- a stale generated table, a
  wrong SONAME and a CR in a `.sh` each make the corresponding check exit
  non-zero. **Not measured on a runner**, and not measured at all for the
  old-name sweep, the endings check or the artefact verifier's floor rule.
- **Approach.** Plant each defect on a branch, push, read the run's conclusion.
  One defect per push, so the red is attributable.
- **Prove.** Six deliberately broken branches, each with the run URL and the
  step that refused, recorded here.

---

## T-11 A machine-readable suite result

- **Source.** The port brief, task 5.0 obstacle 8.
- **Category** infrastructure · **Priority** medium · **Effort** medium ·
  **Status** open
- **Problem.** Both suites report a human summary. Exit status is already
  correct -- non-zero on any MISMATCH -- so CI works today, but a failure is a
  log to scroll rather than an annotated line on the pull request.
- **Premise.** Measured: `grep -c MISMATCH` over a run's output agrees with the
  printed count.
- **Approach.** JUnit XML or JSON emitted **alongside** the human summary, not
  instead of it. ⛔ The `run`/`verdict` helpers in `experiments/*.sh` are where
  the data is, and those files are the tests -- add an optional writer, do not
  restructure the reporting.
- **Prove.** A failing case appears as an annotation on the pull request.

---

## T-12 Measure the stage timeouts on a runner before trusting them

- **Source.** The port brief, task 5.0 obstacle 7.
- **Category** infrastructure · **Priority** medium · **Effort** low ·
  **Status** open
- **Problem.** `timeout 90` (vkcube), `timeout -k 2 30` (GL cases), `timeout 25`
  (hardware glxgears) and `timeout -k 2 35` (gtk4) are wall-clock values tuned on
  one developer machine. ⚠ **A timeout is scored as a FAILURE, not a skip**, so a
  slow shared runner turns into a red build that looks like a regression.
- **Premise.** Measured on the developer machine only.
- **Approach.** Record the actual wall time of each timed case on
  `ubuntu-latest` and on `ubuntu-24.04-arm`. ⛔ **Raise rather than shorten.**
  Shortening hides the problem and makes the failure mode less legible.
- **Prove.** A table of measured-vs-configured per case, in this entry.

---

## T-13 A build error hidden by `2>/dev/null` cost a debugging cycle

- **Source.** Found during the port: adding an include to `src/gl-fwd.c` broke
  the `tgt-fwd.so` build in `experiments/30-run-tests.sh`, and the compiler's
  message was discarded. Ten cases reported `./tramp2: No such file or
  directory`, which names the wrong thing entirely.
- **Category** infrastructure · **Priority** medium · **Effort** low ·
  **Status** open
- **Problem.** Several helper builds in the stages redirect stderr to
  `/dev/null`. When one fails the suite reports a cascade of downstream
  mismatches with no cause in the output.
- **Premise.** Measured -- this happened, and reproducing the compile by hand was
  the only way to see the error.
- **Approach.** ⛔ `experiments/*.sh` are the tests and their assertions must not
  change. Capturing the build's stderr to a file and printing it only on failure
  changes no assertion. That is the shape.
- **Prove.** Break a helper build deliberately; the suite output names the
  compiler error rather than only its consequences.

---

## T-14 Four files that no runner runs

- **Source.** The port brief, task 0.1.
- **Category** infrastructure · **Priority** low · **Effort** low ·
  **Status** ⭐ **DONE**
- **Problem.** ⭐ A test no runner runs is a test that has already stopped
  working and nobody has noticed.
- **Premise.** Measured, by grep over the tree.
  - `tests/allocprobe.c` -- now compiled and smoke-run by the `orphans` job.
  - `tests/icd-harness.c` -- built by `42-build-floor.sh` and invoked by nothing.
    Now compiled and smoke-run by the same job, against a real lavapipe ICD.
    ⚠ **Compiling is not running it against an ICD**, and the `orphans` job
    now fails rather than passing when no ICD is present.
  - `tools/manual/libc_inventory.py` -- what produced `inventories/*.json`. Not run by
    anything. It is a regeneration tool, not a test.
  - `tools/manual/trap_users.py` -- not run by anything.
- **Approach.** Give `icd-harness` a real case in the AppImage suite, or move it
  beside the probe it duplicates. Move the two Python tools to `tools/manual/`
  with one line each saying what they are for.
- ⛔ Do not delete any of them on "nothing runs it" alone -- three of the four are
  cited in documents, and deleting the file without the citation leaves a
  document pointing at nothing.
- **Prove.** `git grep -l` for each name resolves to either a CI job or a
  `tools/manual/README.md` line.

### Closure

The two probes were already covered by the `orphans` job. The two Python tools
moved to [`../tools/manual/`](../tools/manual/README.md), which states what each
is for and who cites it, and every citation moved with them in the same change.

⭐ **The citations are now checked rather than remembered.**
`sh scripts/check-drift.sh` fails when a document cites a repository path that
does not exist, which is exactly the failure mode the "do not delete" rule
above was guarding against by hand. It found both stale citations during this
move, before anything was pushed.

```
$ sh scripts/check-drift.sh
== cited paths ==
  every cited path exists (75 checked)
```

⚠ **What is still not covered:** neither Python tool has been re-run since the
move, so "it still works" is UNVERIFIED. The check proves the path resolves,
not that the tool produces correct output.

---

## T-15 A corpus test with a fresh process per library

- **Source.** Reference sweep of `pg83/solo` --
  [`HISTORY/references/solo-usable.md`](../HISTORY/references/solo-usable.md) §3.
- **Category** infrastructure · **Priority** medium · **Effort** medium ·
  **Status** open
- **Problem.** `tests/corpus.c` loads every library in the host's library
  directory in **one** process and counts successes. Three weaknesses, all of
  which solo's design avoids:
  - one library that corrupts the process changes the verdict on every library
    after it;
  - a lazy load reports success for an object whose relocations would have
    failed at the first call;
  - the output is a count, not a per-symbol view of which ABI entries the
    corpus demands.
- **Premise.** Measured by reading `tst/corpus.py` and `tst/corpus_load.cpp` at
  the recorded commit. ⚠ solo's corpus was **not** run.
- **Approach.** One fresh process per library, `RTLD_NOW`, a fault handler
  installed before the load so a crash is a report rather than a silence, and
  per-library JSON merged afterwards.
- **Prove.** A deliberately corrupting library in the corpus changes exactly one
  row of the result instead of truncating it.

---

## T-16 Delete the path that would mask the failure

- **Source.** Reference sweep of `pg83/solo` --
  [`HISTORY/references/solo-usable.md`](../HISTORY/references/solo-usable.md) §4.
- **Category** infrastructure · **Priority** medium · **Effort** low ·
  **Status** open
- **Problem.** Several cases here *force* a path -- `VK_DRIVER_FILES`,
  `LIBGL_ALWAYS_SOFTWARE`, `CROSS_LIBC_DLOPEN_GL_TARGET` -- but none of them
  removes the alternative that would have worked anyway. A case that forces the
  path under test and leaves the fallback in place cannot distinguish "the
  forced path worked" from "the fallback did".
- **Premise.** Measured by reading `experiments/40-appimage.sh`; solo's
  `nixos-lavapipe` job does the opposite and is quoted in `solo-usable.md` §4.
- **Approach.** ⛔ `experiments/*.sh` are the tests. Removing a masking path
  **changes what a case measures**, which is exactly the kind of edit that must
  not be made casually -- so this is authored per case, with the before and after
  both recorded, not applied as a sweep.
- ⭐ Second, cheaper half: `glprobe` reads one pixel back. Asserting the whole
  frame by hash, with the environment stripped, is strictly stronger and costs
  nothing.
- **Prove.** For each case changed: the case still MATCHes, and the case with
  the forced path *removed* now MISMATCHes where it previously passed.

---

## T-17 The IBT property note is documented and is not there

- **Source.** Review pass 2 of the port: `scripts/verify-artifacts.sh` refused
  a build over it, and the refusal turned out to be right.
- **Category** infrastructure · **Priority** medium · **Effort** medium ·
  **Status** open
- **Problem.** [`docs/REPORT.md`](../docs/REPORT.md) 9 said the shims are built
  `-fcf-protection=full` "so the object carries the matching IBT property note".
  ⛔ **They do not.** The shipped `gl-fwd.so` has only `.note.gnu.build-id`;
  there is no `.note.gnu.property` section at all.
- **Premise.** Measured, three ways, so it is not a property of this source:

  | image | gcc | with the flag | with `-Wl,-z,ibt,-z,shstk` |
  |---|---|---|---|
  | `debian:bullseye-slim` | 10.2.1 | no note | no note |
  | `debian:bookworm-slim` | 12.2.0 | no note | no note |
  | `debian:trixie-slim` | 14.2.0 | no note | no note |

  A one-function shared object with no project code in it behaves identically,
  which is what rules the source out.

  ⚠ The `endbr64` instructions **are** emitted. What is missing is the note
  that tells the loader the object is IBT-capable, and without it a
  CET-enforcing host turns indirect-branch tracking off for the whole process.
  That is a mitigation lost in silence, which is the failure mode this
  repository spends the most words warning about.
- **Approach.** Find a floor toolchain whose gcc is configured with
  `--enable-cet`, or emit the note directly from `src/gl-fwd.c` as an assembler
  `.section .note.gnu.property` block, which is the option that does not move
  the glibc floor. ⭐ The second is likely the right answer, because raising the
  floor to get a note would trade a real portability guarantee for a mitigation.
- **Prove.**
  ```bash
  sh scripts/build.sh && readelf -n build/x86_64/gl-fwd.so | grep -i propert
  ```
  Closes when that prints an `x86 feature: IBT` line and the glibc floor in the
  build manifest has not moved.

---

## T-18 There is no release

- **Source.** The operator, at the end of the port session.
- **Category** infrastructure · **Priority** high · **Effort** medium ·
  **Status** open
- **Problem.** `scripts/build.sh` produces verified artefacts and a manifest,
  and nothing publishes them. A consumer who wants `gl-fwd.so` has to build it,
  which means having a container engine and this repository.
- **Premise.** Measured: the build works on the floor for x86-64 and the
  verifier refuses a build that violates it. ⚠ **The aarch64 half has never been
  built anywhere** -- not locally, not in CI -- so "cross-compiles for aarch64"
  is a property of the script's code and not of any artefact.
- **Approach.** Build both architectures on the floor in CI, run the suites
  against them, and publish on success. ⛔ Every artefact ships three ways --
  loose, `.tar`, `.zip` -- with **no nested directory** inside the archives, so
  an extract drops the files where the user is standing. The release body is
  generated: a changelog, the checksums, the floor and the maximum `GLIBC_*`
  each artefact ended up with.
- ⛔ **Nothing publishes on a red suite**, and nothing publishes from a branch
  that has not been through a pull request.
- **Prove.** A release exists whose assets' checksums match
  `build-manifest.json` for both architectures, and whose body was not written
  by hand.
