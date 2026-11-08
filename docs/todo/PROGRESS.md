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

**`feat/crypt-shim` closes T-07: `crypt(3)` for a musl-built host object.**
The four names are now defined in `src/crypt-shim.c` over musl's vendored
implementation, and `libcrypt.so.1` is no longer loaded into the global scope.
`v0.2.6` predates it, so no released artefact carries the fix.

---

## ⛔ The work order

### 1. `glfwd_try_vendor` accepts a matching filename without checking its class

A host whose only vendor library is the wrong class is reported as having one.
It is a different path from the `glfwd_try_soname` defect fixed in #41, reached
only when the bundle carries a dispatcher, and it needs a bundled-dispatcher
case to measure.

### 2. What is still open

T-02 (`libepoxy`), T-04 (two struct sizes), T-05 (NixOS as a host class), T-06
(the two live struct hazards) and T-10 to T-18. Nothing in this session's
change touches them.

---

## ⚠ What a new session should distrust

- **`libcrypt.so.1` is not a glibc runtime-set member any more, and the three
  wrong answers this session produced are worth not repeating.** Bundling it
  fails because a musl host has none to bundle and a modern one needs
  `GLIBC_2.38`; loading a host copy drags a foreign glibc DSO into the global
  scope; and forwarding `crypt_r` to a real libcrypt without translating the
  struct writes 32768 bytes into musl's 260-byte one (measured: SIGSEGV).
  `src/crypt-shim.c` carries the argument and T-07 the measurements.
- **musl's crypt is not a drop-in for libxcrypt.** It has no yescrypt (`$y$`)
  or scrypt (`$7$`) and treats an unrecognised salt as DES, returning a
  plausible-looking wrong hash rather than failing. That is why the shim
  prefers a real libcrypt, and why E109 exists.
- **Both architecture totals are measured in CI, and the aarch64 one is the
  x86-64 one less the four named skips.** Section 8 owns the numbers; do not
  quote one without a run, and do not raise either one from an estimate.
- **E103 forces the order through `/etc/ld.so.conf.d`, and a host whose own
  answer puts the 64bit directory first never reaches the defect.** Debian 10
  is such a host: `libc6-i386` names `/usr/lib32` and `/lib32` in
  `zz_i386-biarch-compat.conf`, which sorts after `x86_64-linux-gnu.conf`. So
  the case pins the predicate, not a claim about any one distribution.
