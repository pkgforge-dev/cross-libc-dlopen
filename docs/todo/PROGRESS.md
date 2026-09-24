# PROGRESS

⭐ **Read this first, every session.** [`INDEX.md`](INDEX.md) carries the list; this carries the order and the baseline.

⚠ **Rewritten every session. It carries no history.** That is [`../history/`](../history/README.md)'s job.

---

## Where the work is right now

[v0.2.6](https://github.com/pkgforge-dev/cross-libc-dlopen/releases/tag/v0.2.6) is
published.

| workflow | latest on `main` |
|---|---|
| `gates` | ✅ |
| `secret-sweep` | ✅ |
| `release` | ✅ on `v0.2.6` |

**This branch fixes the host lookup that stopped on a library the loader would
refuse, on branch `fix/gl-fwd-wrong-class`, and needs a release once merged.
`v0.2.6` was released from `main` before it, so no released artefact carries
the fix.**

---

## ⛔ The work order

### 1. `glfwd_try_soname` must not stop on a library the loader will refuse

`glfwd_try_soname` took the first directory in which its own soname existed, and
`glfwd_each_dir` stopped the walk there. A candidate of the other ELF class
cannot load, so a host whose own answer named a 32bit library directory first
produced a target that could not load, and the directory after it was never
reached. Reproduced by removing `libGL.so.1` from the host-drivers demo AppDir,
which forces the host path, and naming the 32bit directory first with
`CROSS_LIBC_DLOPEN_GL_HOST_DIR`.

The repair reads the candidate's ELF ident and skips a candidate of the other
class, so the walk continues. `docs/report/09-the-second-boundary.md` 9.21 has
the transcript, E103 is the case, and `docs/report/08-test-results.md` owns the
new totals.

### 2. What is still open

`glfwd_try_vendor` accepts a matching filename without checking its class, so a
host whose only vendor library is the wrong class is reported as having one. It
is a different path, reached only when the bundle carries a dispatcher, and it
needs a bundled-dispatcher case to measure. Nothing in this session's change
touches it.

---

## ⚠ What a new session should distrust

- **E103 forces the order through `/etc/ld.so.conf.d`, and a host whose own
  answer puts the 64bit directory first never reaches the defect.** Debian 10
  is such a host: `libc6-i386` names `/usr/lib32` and `/lib32` in
  `zz_i386-biarch-compat.conf`, which sorts after `x86_64-linux-gnu.conf`. So
  the case pins the predicate, not a claim about any one distribution.
- **The host-drivers demo AppDir bundles the glvnd dispatcher, so the shim
  takes the bundled path on a glvnd host and never reaches the host lookup.**
  Removing `libGL.so.1` from that AppDir is what exposes the path, and the
  deletion is a harness step rather than a change to any shipped AppImage.
- **A Qt6 GLX path does not link `libGL.so.1`.** `libqxcb-glx-integration.so`
  and `libQt6Gui.so.6` need `libGLX.so.0` and `libOpenGL.so.0`, so which arm a
  Qt application reaches depends on what else in its AppDir links
  `libGL.so.1`. Check `readelf -d` before assuming.
- **`docs/todo/INDEX.md` carries the counts it carried before this session.**
  Reconcile them if an entry moves.
