# shell.md

Every rule here has an incident behind it in this repository.

---

## Line endings

⛔ **Shell scripts are LF.** `.gitattributes` enforces it and CI checks it.

A CR turns a script into a `$'...\r'` "not found" error that names the wrong
thing entirely. It reads like a missing binary and it is a line ending.

⚠ **Do not test for a CR with grep.** Measured here: a pattern built with
`$(printf '\r')` matches nothing at all, against a file whose bytes `od -c`
shows ending `\r \n`. The check reads green over a file that demonstrably has
one. This is the form that works:

```bash
tr -d '\r' < "$f" | cmp -s - "$f" || echo "CR in $f"
```

If deleting every CR changes the file, the file had one.

---

## Exit codes

⛔ **Never read an exit code through a pipe.** `$?` after `cmd | tail` is
`tail`'s status, so a check that failed reads as green. Run the check unpiped
and capture its output to a file if you need both.

```bash
sh scripts/verify-gates.sh >/tmp/out 2>&1; rc=$?
```

⭐ **A guard whose test has never been seen to fail is theatre.** Plant the
defect it exists to catch, run it, and read the code. Both halves:  a guard that
refuses a planted defect **and also** refuses a clean tree is not working, it is
stuck. [`../../scripts/verify-gates.sh`](../../scripts/verify-gates.sh) is that
pass, kept runnable.

---

## Functions that report and return

⛔ **A function that prints its report and echoes its result down the same
channel returns its report.** Set a variable instead.

Measured here: a verification function printed three lines and then echoed a
count; the caller's `$( )` captured all four, compared a paragraph against a
number, and declared the controls broken while the measurement on screen said
85.

---

## `timeout` and programs that never exit

⚠ **`timeout` on a program that never exits hangs a `$( )` capture, and it
hangs on the case that WORKED.** `glxgears` does not exit; the timeout kills
the wrapper and leaves children holding the stdout pipe. The case that
*fails* exits immediately and looks fine, so the symptom is exactly inverted
from the fault.

Write to a file and reap.

---

## `ld.so --preload`

⚠ **`ld.so --preload A --preload B` silently keeps only B.** glibc's option
parser holds a single `preloadarg`. The command line reads as if both are
loaded.

```bash
ld.so --preload "A B" ...
```

One flag, space-separated.

⚠ Use `ld.so --preload` rather than `LD_PRELOAD` when a musl binary is anywhere
in the pipeline (`strace`, `env`). `LD_PRELOAD` applies to those too, and
musl's loader cannot load a glibc `.so`.

---

## Every line of a make recipe is its own shell

⚠ A guard that ends in `exit 0` on line one does not stop line two from
running. `gles-syms-check` skipped and then failed anyway, for one revision.
One shell, joined with `&&` or `;` and backslashes.

---

## Placeholders

⛔ **No angle brackets inside a shell block.** A human reads `<appdir>` as "fill
this in" and bash reads it as a redirect, so the reader gets a syntax error
instead of an instruction. Use `"$APPDIR"`.

---

## Quoting and portability

- `sh`, not `bash`, for anything CI or a container runs. The stage scripts are
  POSIX `sh` and one of them is explicitly `bash`; do not mix them by accident.
- Quote every expansion. `$f` in a `for` over `git ls-files` is one space away
  from a bug.
- ⚠ **Do not pass prose inline to a shell.** Backticks execute inside the text,
  even in a quoted heredoc. Write the file with an editor tool instead.
- ⚠ **A heredoc eats backslashes.** Content with line continuations or regex
  escapes goes through a file, not through `<<EOF`.

---

## Windows

⚠ Git Bash on Windows rewrites arguments that look like paths, so
`-v "$PWD:/repo:ro"` reaches `podman` mangled. Prefix with
`MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`. Nothing in the scripts depends on
this; it is the environment.

⚠ `podman machine ssh` drops a file called `NUL` in the working directory on
Windows. `git add` then fails the whole commit with `short read while indexing
NUL`, which reads like repository corruption and is a stray SSH host key.
`rm -f ./NUL`.
