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

## One name in this tree is not this project's

⛔ `$APPDIR/lib/foreign-dlopen.so` is the slot `quick-sharun` writes and
`.preload` names. It stays spelled upstream's way.

⚠ **`.foreign-dlopen-enabled` was the second name here, and is not one any
more.** It is `quick-sharun`'s opt-in marker and an AppDir still carries it,
but nothing in `src/` reads it: the markers were removed and the feature is on
by default whenever the object is preloaded. It stayed listed as load-bearing
in four places for the rest of the branch, and one of them was the comment
explaining why a case passed. [`../REPORT.md`](../REPORT.md) 9.16.

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
trap recorded in [`../../HISTORY/traps.md`](../../HISTORY/traps.md).

Port the orchestration around them. `scripts/run-evidence.sh` and
`scripts/run-appimage.sh` are that layer.

⚠ Where a rename must touch a stage, it changes the emitter **and** the matcher
in the same edit, so the assertion stays equivalent. That is the only kind of
change to these files that does not need a case.
