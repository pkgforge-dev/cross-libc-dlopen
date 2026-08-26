# Reporting a vulnerability

⛔ **Do not open a public issue for a vulnerability.** An issue is readable by
everybody the moment it exists, including before anyone here has read it.

Use GitHub's private reporting on this repository:

**[Report a vulnerability](https://github.com/pkgforge-dev/cross-libc-dlopen/security/advisories/new)**

That opens a draft advisory visible only to the maintainers and to you. If it
is unavailable, open an issue titled `security contact request` containing no
detail, and wait to be contacted.

---

## What is worth reporting

This project makes a process load libraries it would otherwise refuse. The
things that matter most are the ones that widen that:

- A way to make the loader open a path the application did not ask for and the
  bundle does not own.
- A way to make a rewritten object escape `$XDG_RUNTIME_DIR` or `$TMPDIR`, or
  to make the loader write anywhere else.
- A way to get a second libc into the process, since the whole design rests on
  exactly one being there.
- A way to make a shim forward to something other than the single soname it
  impersonates.

⚠ **A crash is worth reporting even when you cannot show it is exploitable.**
This code parses ELF files it did not produce, and a parser that reads out of
bounds is a finding whether or not anybody has written the rest.

---

## What to include

The host and its libc, the bundle and its libc, the command, and what happened.
⭐ **A reproduction beats a description**, and
[`docs/reproducing.md`](docs/reproducing.md) has the harness that most reports
can be expressed in.

---

## What this page is not

⚠ **It is not the document about what CI can do.**
[`docs/security.md`](docs/security.md) covers what a pull request can and
cannot reach here, which is a question about this repository's settings rather
than about a defect in the code. If you are asking whether a fork's pull
request can read a secret, that is the page you want.
