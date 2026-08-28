# code.md

---

## A change to `src/` needs a case

⛔ **A change to the implementation needs a case that FAILS before it and
PASSES after.** Not a case that passes both ways; not a case added afterwards
to describe what the change did.

The suites are [`../reproducing.md`](../reproducing.md). A change with no case
is a change nobody can tell apart from a regression six months later.

---

## Generated files are regenerated, never edited

⛔ These are output, not source:

| file | regenerate with |
|---|---|
| `src/forward-shim.c` | `make -C src shim` |
| `src/forward-shim-manifest.json` | the same |
| `src/gl-fwd-gl.h`, `src/gl-fwd-egl.h` | `make -C src gl-syms GLVND="$APPDIR/lib"` |
| `src/gl-fwd-gles2.h` | `make -C src gles-syms GLES="$APPDIR/lib"` |

`make gl-syms-check`, `make gles-syms-check`, `make traps` and E60 fail on
drift, and CI re-runs the shim generator and diffs the result.

⚠ **`make shim` must be given a musl inventory.** Omitting it drops most of the
definitions and silently disarms the entire musl bridge. `MUSL` has a default
in the Makefile for that reason rather than being something the caller
remembers.

⚠ **`gles-syms-check` exits 0 with a SKIP** when there is no AppDir bundling
`libGLESv2.so.2`. In a job that has not extracted one it passes by skipping, so
it only means anything where one exists.

---

## The floor rule

⛔ **Build on the OLDEST glibc you intend to support, never the newest.**
Everything in [`../building.md`](../building.md) follows from this and it is the
one that looks like a detail. `scripts/build.sh` defaults to a container
because the floor is a property of the build environment, and refuses a native
build by name when the host is newer.

---

## One path in this tree is not spelled by this project

⛔ **The AppDir's dispatcher slot is the file `quick-sharun` writes and
`.preload` names, and its name is upstream's to change.** It has changed:
`lib/foreign-dlopen.so` up to the build hashed `712766f8`, and
`lib/cross-libc-dlopen.so` in the build verified today. So it is READ out of the
extracted AppDir by `experiments/41-extract.sh` and never spelled by us.
[`../report/09-the-second-boundary.md`](../report/09-the-second-boundary.md) 9.17.

⚠ **`.foreign-dlopen-enabled` was the second name here, and is not one any
more.** It is `quick-sharun`'s opt-in marker and an AppDir still carries it,
but nothing in `src/` reads it: the markers were removed and the feature is on
by default whenever the object is preloaded. It stayed listed as load-bearing
in four places for the rest of the branch, and one of them was the comment
explaining why a case passed. [`../report/09-the-second-boundary.md`](../report/09-the-second-boundary.md) 9.16.

⚠ **The `ANYLINUX_*` environment names are a different case and they are
gone.** `src/cld-env.h` no longer reads any of them, because nothing consumed
them. What still sets them is `experiments/40-appimage.sh`, for UPSTREAM's own
binary, which understands no other spelling. Removing them from the harness is
what turns the three controls below into silent passes; removing them from
`src/` did not.

⚠ **Renaming any of them turns E30, E37a and E43a into silent passes**, because
those three drive upstream's own binary and a case that stops receiving the
variable still reports what it predicted.
[`../../scripts/verify-upstream-controls.sh`](../../scripts/verify-upstream-controls.sh)
proves the difference by counting upstream's own debug lines in both arms.

---

## What a comment is for

⛔ **A comment carries what the code cannot say.** A reason, a constraint, a
trap, or a citation of the measurement that established a behaviour. A comment
that restates the line below it is deleted: it costs a reader a line and tells
them nothing the code did not.

```c
/* wrong: the line already says this */
count++;                     // increment the counter

/* right: the code cannot say why */
cld_strip_versions(e);       // every tag at once; a verdef without its
                             // versym table segfaults ld.so
```

⛔ **A file states its purpose once.** One block, at the top. No block lower
down restates it in different words, because the two then drift and a reader
has no way to tell which is current. Where the purpose depends on a rule this
directory owns, the header cites the rule rather than repeating it.

⛔ **A comment narrates no change.** "Before this change those arms could rely
on the variable being unset; now they must say 0, and they do" tells a reader
nothing they can act on: the diff already showed the change, and the sentence
survives it to describe a tree nobody is looking at. That belongs in the commit
message.

⭐ **A rejected alternative is not a changelog, and it is the most valuable
comment in the file.** The difference is what the reader can do with it. A
narration says what happened; a rationale says what will happen to the next
person who tries the obvious thing. Keep the second, with the cost measured:

> THE DEPRECATED ALIASES ARE GONE, and their removal is a decision rather than
> an oversight. Every control had two names, only one of which appeared in any
> document, so a reader could not tell which was authoritative and a check
> could not tell either.

[`../../src/cld-env.h`](../../src/cld-env.h) is the worked example, and
[`../../scripts/build-in-env.sh`](../../scripts/build-in-env.sh) is a second.
⚠ Both read like history at a glance, and neither is: each names a failure
mode that comes back the moment somebody undoes the decision.

⚠ **One comment syntax per file, below the header.** A file header may use the
block form whatever the body uses, which is the ordinary C convention and is
what every file here already does. Below it, whichever syntax already carries
the majority of that file's comments is the one that stays, so bringing a file
into line never produces a diff larger than the change it accompanies.

⚠ Measured when this rule was written: no file in `src/` mixes the two. The
rule exists to keep that true, not to license a rewrite of one that does not.

⛔ **A comment defect in a generated file is fixed at its generator.** The four
files above are output. Editing one directly is refused by the regeneration
checks, because regenerating no longer reproduces it.

⚠ **A comment in `experiments/*.sh` is edited only where it is provably a
comment.** Those files carry the assertions, and the rule below governs
everything else in them.

---

## The implementation invariants

⛔ **Each of these is here because the opposite was tried.** They govern
`src/`, and a change that breaks one is a change that needs a case before it
needs a review.

- **Never modify a host file.** Every write goes under `$XDG_RUNTIME_DIR` or
  `$TMPDIR`. [`../../tests/invariants.c`](../../tests/invariants.c) and the
  checksum comparison in [`../report/README.md`](../report/README.md) guard this.
- **Exactly one libc family per process.** Never `dlopen` a second libc. E8 and
  E9 measure why for glibc. musl's libc *can* be mapped by a glibc `ld.so`,
  which is worse rather than better, because it succeeds quietly.
- **Bundled libraries always beat host libraries**, for everything except the
  libc runtime set when Design R deliberately switches it.
- **Never strip symbol versions partially.** `DT_VERSYM`, `DT_VERNEED`,
  `DT_VERDEF` and `DT_VERDEFNUM` go together. A verdef without its versym
  segfaults `ld.so`.
- **Strip only when the object actually needs it.** A rewritten object is a
  private copy loaded from a path the application did not ask for, and the
  Vulkan loader says so. On a host that can satisfy every requirement, the
  right number of rewrites is zero.
- **Never touch `ld-linux*`, `libc.so.*`, `ld-musl*`.** `cld_never_touch[]`
  exists for this. `ld-linux` has no `SONAME`, so `RTLD_NOLOAD` cannot catch
  it.
- **Anything appended to a library path goes at the END.** Bundled directories
  first, then the host runtime dir, then the conventional host dirs, then
  whatever `/etc/ld.so.conf` names. Inserting anywhere else hands a host
  library a win it should not have.

---

## Finding libraries is not this project's job

⛔ **Do not add library searching to `src/cross-libc-dlopen.c`.** That is
`ld.so`'s job, driven by `--library-path`. Two search implementations would
diverge, and the C one would be the buggy one.

⭐ **Assembling that path is a different job, and it belongs to whatever
launches the process.** Two launchers needed the same fix independently:
sharun assembles the path for the bundled runtime, fixed upstream in
[Anylinux-sharun@`54208d2`](https://github.com/pkgforge-dev/Anylinux-sharun/commit/54208d2bc7d4c919ba46a6c234f6af7f8426b537),
and `rs_library_path()` in
[`../../src/runtime-select.c`](../../src/runtime-select.c) assembles it for the
switched one. Adding a directory to a path is not searching it, and the shim
still never opens a library it was not handed by name.

⚠ **[`../../src/gl-fwd.c`](../../src/gl-fwd.c) is the one deliberate exception,
and it is bounded.** It resolves exactly ONE soname, the one it is
impersonating, because `ld.so` cannot: that name is taken by the shim itself,
so `dlopen("libGL.so.1")` would hand back the shim's own handle and every
forward would recurse. A closed, single-name lookup over a fixed directory list
plus `CROSS_LIBC_DLOPEN_GL_HOST_DIR` is not a search implementation, and it
must not grow into one.

---

## Naming

- New environment variables take the `CROSS_LIBC_DLOPEN_` prefix and go through
  `cld_getenv(name, NULL)` in `src/cld-env.h`. A new control has no deprecated
  alias, and `NULL` is how that is said.
- Internal identifiers are `cld_` / `CLD_`; exported ones are
  `cross_libc_dlopen_`.
- ⭐ Prefer a neutral accurate name to an evocative one.

---

## Tests

⛔ **A test whose success condition is "a string appeared" passes a broken
implementation.** The probes in [`../../tests/`](../../tests/) clear to a known
colour and read the pixel back for exactly that reason. Keep that property in
anything new.

⛔ **Never single-sided.** Run the feature off and on. "It worked" cannot tell a
fix from a fallback that was already happening.

⚠ **A test you cannot run is SKIPPED with the specific missing capability
named.** Never silently omitted, never guessed.

---

## `experiments/*.sh` are the tests

⛔ Every `run` and `verdict` line states a prediction the harness scores.
Rewriting one in another language, "cleaning up" a grep, or making an assertion
tidier silently changes what is being asserted. Several look odd because of a
trap recorded in [`../history/traps.md`](../history/traps.md).

Port the orchestration around them. `scripts/run-evidence.sh` and
`scripts/run-appimage.sh` are that layer.

⚠ Where a rename must touch a stage, it changes the emitter **and** the matcher
in the same edit, so the assertion stays equivalent. That is the only kind of
change to these files that does not need a case.
