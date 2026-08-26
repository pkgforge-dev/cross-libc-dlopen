#!/usr/bin/env python3
"""
Generate the forward-compatibility shim (Design B).

Answers 4.1's treadmill objection by GENERATING the shim from glibc's own
symbol tables instead of hand-patching per bug report.  It does NOT give
forward compatibility -- 4.5 explains why only Design R can.  This covers the
*enumerable* gap: symbols that exist in a newer glibc today and are absent
from the floor we actually bundle.

    python3 tools/gen_forward_shim.py \
        --floor  inv/appdir.json \
        --target inv/arch.json \
        --out    src/forward-shim.c \
        --manifest src/forward-shim-manifest.json

What is generated vs. what is audited
-------------------------------------
The *selection* is generated: which symbols the floor lacks, and which bucket
each falls in.  The *implementations* come from the audited table below -- a
generator that invented semantics would be worse than the treadmill, not
better.  Solo splits it the same way (generate_glibc_stubs.py + glibc_shim.cpp).

Buckets (5.2 step 2):
  implementable  a small correct implementation over the older glibc
  forwardable    an alias of something already present
  stub-only      cannot be implemented; aborts naming the symbol if called
  irrelevant     glibc internals no dlopen'd driver can reach; not emitted
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from libc_inventory import version_key  # noqa: E402

# ---------------------------------------------------------------------------
# irrelevant: glibc-internal surfaces a dlopen'd driver cannot reach.
# Matching here means "deliberately not shimmed", not "forgotten".
# ---------------------------------------------------------------------------
IRRELEVANT_RE = [
    (r"^GLIBC_", "glibc ABI version marker: a zero-sized SHN_ABS entry in "
                 ".dynsym, not a callable symbol"),
    (r"^_thread_db_", "libthread_db internals; debugger-only"),
    (r"^__?nss_", "NSS plumbing; reached only through glibc's own resolver"),
    (r"^_nss_", "NSS module entry points"),
    (r"^__rtld_", "ld.so internals"),
    (r"^_dl_(?!find_object$)", "ld.so internals (except _dl_find_object)"),
    (r"^__libc_(?!single_threaded$)", "glibc internals (except __libc_single_threaded)"),
    (r"_version_placeholder$", "empty ABI placeholder symbol"),
    (r"^__gai_|^__getaddrinfo", "libanl internals"),
    (r"^_?_?res_", "resolver internals"),
    (r"^__(dn|ns)_", "resolver internals"),
    (r"^__pthread_(?!attr)", "NPTL internals"),
    (r"^__(vfscanf|vfprintf|vsyslog|isoc(23|99|2x))", "printf/scanf internal entry points"),
    (r"^__(x|f|l)?stat|^__xmknod", "the *_VER stat/mknod entry points we shim FROM"),
    (r"^_IO_", "stdio internals"),
    (r"^__ctype|^__c(type|locale)", "locale table internals"),
    (r"^__tls_|^__libc_tls", "TLS internals owned by ld.so"),
    # These look musl-only against a libc/libm/split-lib inventory, but glibc
    # ships them in libcrypt.so.1, which cross-libc-dlopen.c now loads into the
    # global scope precisely so re-homed names resolve (B4). Shimming them
    # would INTERPOSE over the real implementation and abort a working call.
    (r"^(crypt|crypt_r|encrypt|encrypt_r|setkey|setkey_r)$",
     "glibc provides this in libcrypt.so.1, which B4 loads RTLD_GLOBAL; "
     "shimming it would interpose over a working implementation"),
    # ELF machinery, not API. _init/_fini ARE the .init/.fini sections and are
    # supplied by crti.o; defining them is a multiple-definition link error.
    (r"^(_init|_fini)$",
     "the .init/.fini sections themselves, supplied by crti.o"),
    (r"^(_dlstart|__dls2b?|__dls3|_dl_debug_addr)$",
     "musl's own dynamic-loader internals; there is no musl ld.so here"),
]

# ---------------------------------------------------------------------------
# The audited implementation table.
#
# kind: implementable | forwardable | stub-only
# Every entry is hand-reviewed.  `needs` names symbols the implementation calls
# that must exist at the floor, and the generator verifies that and downgrades to
# stub-only if the prerequisite is missing, so a wrong floor cannot silently
# produce a broken shim.
# ---------------------------------------------------------------------------
IMPL = {}


def _impl(name, kind, code, needs=(), headers=(), note=""):
    IMPL[name] = dict(kind=kind, code=code, needs=list(needs),
                      headers=list(headers), note=note)


# --- BSD string ------------------------------------------------------------
_impl("strlcpy", "implementable", r"""
SHIM(size_t) strlcpy(char *d, const char *s, size_t n) {
	size_t sl = strlen(s);
	if (n) { size_t c = sl < n - 1 ? sl : n - 1; memcpy(d, s, c); d[c] = '\0'; }
	return sl;
}""", needs=["strlen", "memcpy"], headers=["<string.h>"],
      note="glibc 2.38; OpenBSD semantics, returns strlen(src)")

_impl("strlcat", "implementable", r"""
SHIM(size_t) strlcat(char *d, const char *s, size_t n) {
	size_t dl = strnlen(d, n);
	if (dl == n) return n + strlen(s);
	return dl + strlcpy(d + dl, s, n - dl);
}""", needs=["strnlen", "strlen"], headers=["<string.h>"],
      note="glibc 2.38")

_impl("wcslcpy", "implementable", r"""
SHIM(size_t) wcslcpy(wchar_t *d, const wchar_t *s, size_t n) {
	size_t sl = wcslen(s);
	if (n) { size_t c = sl < n - 1 ? sl : n - 1;
	         wmemcpy(d, s, c); d[c] = L'\0'; }
	return sl;
}""", needs=["wcslen", "wmemcpy"], headers=["<wchar.h>"], note="glibc 2.38")

_impl("wcslcat", "implementable", r"""
SHIM(size_t) wcslcat(wchar_t *d, const wchar_t *s, size_t n) {
	size_t dl = wcsnlen(d, n);
	if (dl == n) return n + wcslen(s);
	return dl + wcslcpy(d + dl, s, n - dl);
}""", needs=["wcsnlen", "wcslen"], headers=["<wchar.h>"], note="glibc 2.38")

# --- arc4random ------------------------------------------------------------
_impl("arc4random_buf", "implementable", r"""
SHIM(void) arc4random_buf(void *b, size_t n) {
	unsigned char *p = (unsigned char *)b;
	while (n) {
		long r = syscall(SYS_getrandom, p, n, 0);
		if (r < 0) {
			if (errno == EINTR) continue;
			break;                       /* fall through to the fd path */
		}
		if (r == 0) break;
		p += (size_t)r; n -= (size_t)r;
	}
	if (n) {                                 /* pre-3.17 kernel or blocked */
		int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
		if (fd >= 0) {
			while (n) {
				ssize_t r = read(fd, p, n);
				if (r < 0 && errno == EINTR) continue;
				if (r <= 0) break;
				p += (size_t)r; n -= (size_t)r;
			}
			close(fd);
		}
	}
	if (n) shim_fatal("arc4random_buf", "no entropy source available");
}""", needs=["syscall", "open", "read", "close"],
      headers=["<sys/syscall.h>", "<unistd.h>", "<fcntl.h>", "<errno.h>"],
      note="glibc 2.36; getrandom(2) with a /dev/urandom fallback. "
           "Aborts rather than return predictable bytes.")

_impl("arc4random", "implementable", r"""
SHIM(uint32_t) arc4random(void) {
	uint32_t v; arc4random_buf(&v, sizeof v); return v;
}""", needs=["syscall"], headers=["<stdint.h>"], note="glibc 2.36")

_impl("arc4random_uniform", "implementable", r"""
SHIM(uint32_t) arc4random_uniform(uint32_t upper) {
	/* Rejection sampling: a bare % is biased, and callers of this API are
	   usually the ones that care. */
	if (upper < 2) return 0;
	uint32_t min = (uint32_t)(-upper) % upper, r;
	do { r = arc4random(); } while (r < min);
	return r % upper;
}""", needs=["syscall"], headers=["<stdint.h>"], note="glibc 2.36; unbiased")

# --- stat family (real symbols only from 2.33; before that only __xstat) ----
for _n, _vn, _proto, _args in [
    ("stat",     "__xstat",     "const char *p, struct stat *b",              "p, b"),
    ("lstat",    "__lxstat",    "const char *p, struct stat *b",              "p, b"),
    ("fstat",    "__fxstat",    "int fd, struct stat *b",                     "fd, b"),
    ("fstatat",  "__fxstatat",  "int fd, const char *p, struct stat *b, int f", "fd, p, b, f"),
    ("stat64",   "__xstat64",   "const char *p, struct stat64 *b",            "p, b"),
    ("lstat64",  "__lxstat64",  "const char *p, struct stat64 *b",            "p, b"),
    ("fstat64",  "__fxstat64",  "int fd, struct stat64 *b",                   "fd, b"),
    ("fstatat64", "__fxstatat64", "int fd, const char *p, struct stat64 *b, int f", "fd, p, b, f"),
]:
    _sb = "struct stat64" if _n.endswith("64") else "struct stat"
    _xa = _args.replace("p, b", "p, b").replace("fd, b", "fd, b")
    _impl(_n, "implementable", f"""
extern int {_vn}(int, {_proto.replace('const char *p', 'const char *').replace('struct stat64 *b', '%s *' % _sb).replace('struct stat *b', 'struct stat *').replace('int fd', 'int').replace('int f', 'int')});
SHIM(int) {_n}({_proto}) {{
	return {_vn}(SHIM_STAT_VER, {_xa});
}}""", needs=[_vn], headers=["<sys/stat.h>"],
          note=f"glibc 2.33 exported {_n} directly; before that only {_vn} existed")

for _n, _vn, _proto, _args in [
    ("mknod",   "__xmknod",   "const char *p, mode_t m, dev_t d",         "p, m, &d"),
    ("mknodat", "__xmknodat", "int fd, const char *p, mode_t m, dev_t d", "fd, p, m, &d"),
]:
    _pre = "int, " if _n == "mknodat" else ""
    _impl(_n, "implementable", f"""
extern int {_vn}(int, {_pre}const char *, mode_t, dev_t *);
SHIM(int) {_n}({_proto}) {{
	return {_vn}(SHIM_STAT_VER, {_args});
}}""", needs=[_vn], headers=["<sys/stat.h>", "<sys/sysmacros.h>"],
          note="glibc 2.33; note __xmknod takes dev_t BY POINTER")

# --- syscall wrappers ------------------------------------------------------
_SYSCALLS = [
    ("close_range", "int", "unsigned int f, unsigned int l, int flags", "f, l, flags",
     "SYS_close_range", 436, "glibc 2.34"),
    ("execveat", "int", "int fd, const char *p, char *const av[], char *const ev[], int flags",
     "fd, p, av, ev, flags", "SYS_execveat", 322, "glibc 2.34"),
    ("pidfd_open", "int", "pid_t pid, unsigned int flags", "pid, flags",
     "SYS_pidfd_open", 434, "glibc 2.36"),
    ("pidfd_getfd", "int", "int pidfd, int targetfd, unsigned int flags", "pidfd, targetfd, flags",
     "SYS_pidfd_getfd", 438, "glibc 2.36"),
    ("pidfd_send_signal", "int", "int pidfd, int sig, siginfo_t *info, unsigned int flags",
     "pidfd, sig, info, flags", "SYS_pidfd_send_signal", 424, "glibc 2.36"),
    ("process_madvise", "ssize_t", "int pidfd, const struct iovec *iov, size_t n, int adv, unsigned int flags",
     "pidfd, iov, n, adv, flags", "SYS_process_madvise", 440, "glibc 2.36"),
    ("fsopen", "int", "const char *fsname, unsigned int flags", "fsname, flags",
     "SYS_fsopen", 430, "glibc 2.36"),
    ("fsmount", "int", "int fd, unsigned int flags, unsigned int attr", "fd, flags, attr",
     "SYS_fsmount", 432, "glibc 2.36"),
    ("fspick", "int", "int dfd, const char *p, unsigned int flags", "dfd, p, flags",
     "SYS_fspick", 433, "glibc 2.36"),
    ("open_tree", "int", "int dfd, const char *p, unsigned int flags", "dfd, p, flags",
     "SYS_open_tree", 428, "glibc 2.36"),
    ("move_mount", "int", "int ffd, const char *fp, int tfd, const char *tp, unsigned int flags",
     "ffd, fp, tfd, tp, flags", "SYS_move_mount", 429, "glibc 2.36"),
    ("mount_setattr", "int", "int dfd, const char *p, unsigned int flags, struct mount_attr *a, size_t sz",
     "dfd, p, flags, a, sz", "SYS_mount_setattr", 442, "glibc 2.36"),
    ("memfd_create", "int", "const char *name, unsigned int flags", "name, flags",
     "SYS_memfd_create", 319, "glibc 2.27"),
    ("gettid", "pid_t", "void", "", "SYS_gettid", 186, "glibc 2.30"),
    ("getrandom", "ssize_t", "void *buf, size_t n, unsigned int flags", "buf, n, flags",
     "SYS_getrandom", 318, "glibc 2.25"),
    ("copy_file_range", "ssize_t",
     "int fdi, __off64_t *offi, int fdo, __off64_t *offo, size_t len, unsigned int flags",
     "fdi, offi, fdo, offo, len, flags", "SYS_copy_file_range", 326, "glibc 2.27"),
]
for _n, _ret, _proto, _args, _sysname, _sysnum, _note in _SYSCALLS:
    _call = f"syscall({_sysname}" + (f", {_args}" if _args else "") + ")"
    _impl(_n, "implementable", f"""
#ifndef {_sysname}
#define {_sysname} {_sysnum}   /* x86-64 */
#endif
SHIM({_ret}) {_n}({_proto}) {{
	return ({_ret}){_call};
}}""", needs=["syscall"],
          headers=["<sys/syscall.h>", "<unistd.h>", "<sys/uio.h>", "<signal.h>"],
          note=_note + "; thin syscall wrapper, errno set by syscall(2)")

# --- misc ------------------------------------------------------------------
_impl("mallinfo2", "implementable", r"""
struct shim_mallinfo2 {
	size_t arena, ordblks, smblks, hblks, hblkhd, usmblks,
	       fsmblks, uordblks, fordblks, keepcost;
};
SHIM(struct shim_mallinfo2) mallinfo2(void) {
	struct mallinfo m = mallinfo();
	struct shim_mallinfo2 o;
	/* Widening int->size_t. Values above 2 GiB were already wrong in the
	   int-based mallinfo(); this cannot recover information glibc lost. */
	o.arena    = (size_t)(unsigned)m.arena;
	o.ordblks  = (size_t)(unsigned)m.ordblks;
	o.smblks   = (size_t)(unsigned)m.smblks;
	o.hblks    = (size_t)(unsigned)m.hblks;
	o.hblkhd   = (size_t)(unsigned)m.hblkhd;
	o.usmblks  = (size_t)(unsigned)m.usmblks;
	o.fsmblks  = (size_t)(unsigned)m.fsmblks;
	o.uordblks = (size_t)(unsigned)m.uordblks;
	o.fordblks = (size_t)(unsigned)m.fordblks;
	o.keepcost = (size_t)(unsigned)m.keepcost;
	return o;
}""", needs=["mallinfo"], headers=["<malloc.h>"],
      note="glibc 2.33; widens the int-based mallinfo. Lossy above 2 GiB "
           "by construction -- the old struct never held those values.")

_impl("_dl_find_object", "implementable", r"""
SHIM(int) _dl_find_object(void *address, void *result) {
	/* glibc 2.35. Returning -1 is the documented 'not found' answer; every
	   in-tree unwinder falls back to dl_iterate_phdr, which the older ld.so
	   implements correctly. Deliberately does NOT touch *result. */
	(void)address; (void)result;
	return -1;
}""", headers=[], note="glibc 2.35; -1 makes callers use dl_iterate_phdr")

_impl("__libc_single_threaded", "implementable", r"""
/* glibc 2.32 data symbol. libstdc++ reads it to skip atomics. 0 = 'may be
   multithreaded' is always safe; 1 would be an optimisation we cannot prove. */
SHIM_DATA(char) __libc_single_threaded = 0;""",
      headers=[], note="glibc 2.32; data symbol, conservative value 0")

for _n, _arr, _note in [
    ("sigabbrev_np", "sys_sigabbrev", "glibc 2.32"),
    ("sigdescr_np", "sys_siglist", "glibc 2.32"),
]:
    _impl(_n, "implementable", f"""
extern const char *const {_arr}[];
SHIM(const char *) {_n}(int sig) {{
	if (sig <= 0 || sig >= NSIG) return NULL;
	return {_arr}[sig];
}}""", needs=[_arr], headers=["<signal.h>"], note=_note)

_impl("strerrorname_np", "stub-only", "", headers=[],
      note="glibc 2.32; needs the errno-name table, which older glibc does "
           "not export in any form. Cannot be implemented -- aborts if called.")

_impl("strerrordesc_np", "implementable", r"""
SHIM(const char *) strerrordesc_np(int e) {
	/* glibc 2.32. strerror() is the same text; it is not thread-safe in
	   theory but returns a static string for known errno values, which is
	   the only case this API is defined for. */
	return e >= 0 ? strerror(e) : NULL;
}""", needs=["strerror"], headers=["<string.h>"], note="glibc 2.32")

# --- atexit: absent from EVERY glibc libc.so.6 (lives in libc_nonshared.a) ---
_impl("atexit", "implementable", r"""
static void shim_atexit_thunk(void *p) {
	/* Calling through the correct prototype: no function-pointer cast, so
	   no reliance on %rdi being ignored. */
	union { void *o; void (*f)(void); } u;
	u.o = p;
	u.f();
}
SHIM(int) atexit(void (*fn)(void)) {
	union { void *o; void (*f)(void); } u;
	/* glibc marks the parameter nonnull, so it warns about this check; a
	   musl-built caller is not bound by that attribute, so keep it. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull-compare"
	if (!fn) return -1;
#pragma GCC diagnostic pop
	u.f = fn;
	/* dso_handle NULL => runs at exit(). Host objects load RTLD_NODELETE,
	   so a handler can never outlive its object. */
	return __cxa_atexit(shim_atexit_thunk, u.o, NULL);
}""", needs=["__cxa_atexit"], headers=["<stdlib.h>"],
      note="MUSL BRIDGE (5.1 Design A), not a version gap: glibc keeps atexit "
           "in the static libc_nonshared.a at every release, musl exports it "
           "dynamically. Measured absent from the bundled libc.so.6.")

_impl("issetugid", "implementable", r"""
SHIM(int) issetugid(void) {
	/* musl exports this BSD call; glibc has never had it. The kernel already
	   answers the question through AT_SECURE, which is exactly what musl's
	   own implementation reads, so this is a faithful port, not a guess.
	   Measured: this ONE symbol was the only thing blocking libX11.so.6 and
	   libdbus-1.so.3 in the Alpine corpus test. */
	errno = 0;
	unsigned long secure = getauxval(AT_SECURE);
	if (errno == 0)
		return secure ? 1 : 0;
	/* Pre-2.19 glibc, or no auxv entry: fall back to the id comparison,
	   which misses file capabilities but never claims safety it lacks. */
	return (getuid() != geteuid() || getgid() != getegid()) ? 1 : 0;
}""", needs=["getauxval"], headers=["<sys/auxv.h>", "<errno.h>", "<unistd.h>"],
      note="MUSL BRIDGE: BSD issetugid over AT_SECURE, as musl implements it")

_impl("fpurge", "implementable", r"""
SHIM(int) fpurge(FILE *f) {
	/* musl's BSD-flavoured name for glibc's __fpurge, which is the same
	   operation with a void return. */
	__fpurge(f);
	return 0;
}""", needs=["__fpurge"], headers=["<stdio.h>", "<stdio_ext.h>"],
      note="MUSL BRIDGE: BSD fpurge over glibc's __fpurge")

_impl("posix_close", "implementable", r"""
SHIM(int) posix_close(int fd, int flags) {
	/* POSIX 2024. Only POSIX_CLOSE_RESTART (0) is defined, and Linux never
	   restarts close(2), so this is exactly close(). */
	(void)flags;
	return close(fd);
}""", needs=["close"], headers=["<unistd.h>"], note="MUSL BRIDGE")

for _n, _g in [("_IO_getc_unlocked", "getc_unlocked"),
               ("_IO_putc_unlocked", "putc_unlocked"),
               ("_IO_feof_unlocked", "feof_unlocked"),
               ("_IO_ferror_unlocked", "ferror_unlocked")]:
    _arg = "FILE *f" if _n.endswith(("feof_unlocked", "ferror_unlocked",
                                     "getc_unlocked")) else "int c, FILE *f"
    _call = f"{_g}(f)" if "putc" not in _n else f"{_g}(c, f)"
    _impl(_n, "implementable", f"""
SHIM(int) {_n}({_arg}) {{
	/* musl exports these as real symbols; glibc defines them as macros over
	   the unsuffixed name, so the symbol is absent from libc.so.6. */
	return {_call};
}}""", needs=[_g], headers=["<stdio.h>"], note="MUSL BRIDGE: macro in glibc")

_impl("__strerror_l", "implementable", r"""
SHIM(char *) __strerror_l(int e, locale_t loc) {
	return strerror_l(e, loc);
}""", needs=["strerror_l"], headers=["<string.h>", "<locale.h>"],
      note="MUSL BRIDGE: glibc spells it without the underscores")

_impl("membarrier", "implementable", r"""
#ifndef SYS_membarrier
#define SYS_membarrier 324   /* x86-64 */
#endif
SHIM(int) membarrier(int cmd, unsigned int flags, int cpu_id) {
	return (int)syscall(SYS_membarrier, cmd, flags, cpu_id);
}""", needs=["syscall"], headers=["<sys/syscall.h>", "<unistd.h>"],
      note="MUSL BRIDGE: thin syscall wrapper")

for _n, _req in [("tcgetwinsize", "TIOCGWINSZ"), ("tcsetwinsize", "TIOCSWINSZ")]:
    _cv = "struct winsize *ws" if _n.startswith("tcget") else "const struct winsize *ws"
    _impl(_n, "implementable", f"""
SHIM(int) {_n}(int fd, {_cv}) {{
	/* POSIX 2024, present in musl. glibc callers use the ioctl directly. */
	return ioctl(fd, {_req}, ws);
}}""", needs=["ioctl"], headers=["<sys/ioctl.h>", "<termios.h>"],
          note="MUSL BRIDGE: ioctl under a POSIX name")

_impl("at_quick_exit", "implementable", r"""
SHIM(int) at_quick_exit(void (*fn)(void)) {
	/* Same libc_nonshared.a situation as atexit. glibc's real at_quick_exit
	   runs handlers on quick_exit() only; approximating with __cxa_atexit
	   would run them on normal exit too, which is WRONG. Registering
	   nothing and reporting failure is the honest answer. */
	(void)fn;
	return -1;
}""", headers=["<stdlib.h>"],
      note="MUSL BRIDGE. Returns failure rather than register a handler with "
           "the wrong lifetime. Callers must handle a non-zero return.")


# --- C23 stdc_* bit utilities: generated, not hand-written ------------------
_STDC_W = [("uc", "unsigned char", 8), ("us", "unsigned short", 16),
           ("ui", "unsigned int", 32), ("ul", "unsigned long", 64),
           ("ull", "unsigned long long", 64)]


def _gen_stdc():
    """The 70 C23 bit utilities: 14 families x 5 widths, from compiler builtins."""
    for suf, ty, bits in _STDC_W:
        p = "(unsigned long long)v"
        body = {
            "leading_zeros":      f"return v ? (unsigned)(__builtin_clzll({p}) - (64 - {bits})) : {bits};",
            "leading_ones":       f"{ty} n = ({ty})~v; return n ? (unsigned)(__builtin_clzll((unsigned long long)n & SHIM_M({bits})) - (64 - {bits})) : {bits};",
            "trailing_zeros":     f"return v ? (unsigned)__builtin_ctzll({p}) : {bits};",
            "trailing_ones":      f"{ty} n = ({ty})~v; return n ? (unsigned)__builtin_ctzll((unsigned long long)n) : {bits};",
            "first_leading_zero": f"{ty} n = ({ty})~v; return n ? (unsigned)(__builtin_clzll((unsigned long long)n & SHIM_M({bits})) - (64 - {bits})) + 1u : 0u;",
            "first_leading_one":  f"return v ? (unsigned)(__builtin_clzll({p}) - (64 - {bits})) + 1u : 0u;",
            "first_trailing_zero": f"{ty} n = ({ty})~v; return n ? (unsigned)__builtin_ctzll((unsigned long long)n) + 1u : 0u;",
            "first_trailing_one": f"return v ? (unsigned)__builtin_ctzll({p}) + 1u : 0u;",
            "count_zeros":        f"return {bits}u - (unsigned)__builtin_popcountll({p} & SHIM_M({bits}));",
            "count_ones":         f"return (unsigned)__builtin_popcountll({p} & SHIM_M({bits}));",
        }
        for fam, code in body.items():
            _impl(f"stdc_{fam}_{suf}", "implementable",
                  f"\nSHIM(unsigned) stdc_{fam}_{suf}({ty} v) {{\n\t{code}\n}}",
                  headers=[], note=f"C23 bit utility (glibc 2.39), {bits}-bit")
        _impl(f"stdc_has_single_bit_{suf}", "implementable", f"""
SHIM(_Bool) stdc_has_single_bit_{suf}({ty} v) {{
	return v && !(v & ({ty})(v - 1));
}}""", headers=[], note=f"C23 bit utility (glibc 2.39), {bits}-bit")
        _impl(f"stdc_bit_width_{suf}", "implementable", f"""
SHIM(unsigned) stdc_bit_width_{suf}({ty} v) {{
	return v ? (unsigned)({bits} - (__builtin_clzll({p}) - (64 - {bits}))) : 0u;
}}""", headers=[], note=f"C23 bit utility (glibc 2.39), {bits}-bit")
        _impl(f"stdc_bit_floor_{suf}", "implementable", f"""
SHIM({ty}) stdc_bit_floor_{suf}({ty} v) {{
	return v ? ({ty})(({ty})1 << ({bits} - 1 - (__builtin_clzll({p}) - (64 - {bits})))) : ({ty})0;
}}""", headers=[], note=f"C23 bit utility (glibc 2.39), {bits}-bit")
        _impl(f"stdc_bit_ceil_{suf}", "implementable", f"""
SHIM({ty}) stdc_bit_ceil_{suf}({ty} v) {{
	/* C23: wraps to 0 when the result is not representable. */
	if (v <= 1) return ({ty})1;
	unsigned w = (unsigned)({bits} - (__builtin_clzll((unsigned long long)({ty})(v - 1)) - (64 - {bits})));
	return w >= {bits} ? ({ty})0 : ({ty})(({ty})1 << w);
}}""", headers=[], note=f"C23 bit utility (glibc 2.39), {bits}-bit")


_gen_stdc()

# ---------------------------------------------------------------------------
# C23 / IEEE-754-2019 math.  Deliberately stub-only.
#
# These have exacting NaN, signed-zero and rounding-mode semantics.  An
# approximation that is subtly wrong is worse than a loud abort, and no GPU
# driver calls sinpi().  Recorded so the classification is explicit rather
# than an oversight.
# ---------------------------------------------------------------------------
MATH_RE = re.compile(
    r"^(a?(cos|sin|tan)pi|exp(2|10)m1|log(2|10)p1|logp1|"
    r"f(maximum|minimum)(_num|_mag|_mag_num)?|roundeven|fromfp[xf]?|ufromfp[x]?|"
    r"nextup|nextdown|totalorder(mag)?|setpayload(sig)?|getpayload|canonicalize|"
    r"compoundn|pown?|rootn|rsqrt|scalbn?|llogb|daddl?|dmull?|dsubl?|ddivl?|"
    r"f32|f64|f128|fadd|fsub|fmul|fdiv)"
    r"(f|l|f16|f32|f32x|f64|f64x|f128|f128x)?$")


def classify(sym, floor_syms, kind=None):
    """(bucket, reason) for one symbol the floor lacks."""
    # Structural check first: an SHN_ABS zero-sized entry is an ABI marker,
    # whatever it is called. Cheaper to trust the ELF than a name pattern.
    if kind and kind.get("abs") and not kind.get("size"):
        return "irrelevant", ("zero-sized SHN_ABS entry: an ABI marker, not a "
                              "callable or readable symbol")
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", sym):
        return "irrelevant", "not a valid C identifier; cannot be defined in C"

    # An audited entry wins over the irrelevant patterns: writing an
    # implementation IS the decision that this symbol matters. Otherwise the
    # broad "^_IO_ is stdio internals" rule would discard _IO_getc_unlocked,
    # which musl really does export and host objects really do import.
    ent = IMPL.get(sym)
    if ent:
        missing = [n for n in ent["needs"] if n not in floor_syms]
        if missing:
            return "stub-only", (f"implementation needs {', '.join(missing)}, "
                                 f"absent from the floor")
        return ent["kind"], ent["note"]

    for pat, why in IRRELEVANT_RE:
        if re.search(pat, sym):
            return "irrelevant", why
    if MATH_RE.match(sym):
        return "stub-only", ("C23/IEEE-754-2019 math: exact NaN, signed-zero and "
                             "rounding semantics; an approximation would be "
                             "silently wrong")
    return "stub-only", "no audited implementation"


PROLOGUE = r"""/* GENERATED by tools/gen_forward_shim.py. Do not edit by hand.
 *
 * Forward-compatibility shim (Design B).
 *
 * Covers the ENUMERABLE gap: symbols a newer glibc exports that the runtime
 * we bundle does not.  It does NOT and cannot cover symbols invented after
 * this file was generated. That is Design R's job (REPORT.md, and E12).
 *
 * Anything outside the covered set aborts naming the symbol.  Solo's
 * discipline: silent corruption is worse than a loud failure.
 *
 * Why stubs at all: every Mesa object is DF_BIND_NOW, so ld.so resolves the
 * whole symbol table at load.  ONE undefined symbol makes the library
 * unloadable even if that code path is never taken.  A stub converts
 * "cannot load at all" into "works unless it genuinely needs this".
 *
 *   floor  : %(floor_name)s (glibc %(floor_release)s)
 *   target : %(target_name)s (glibc %(target_release)s)
 *   covered: %(n_impl)d implementable, %(n_fwd)d forwardable, %(n_stub)d stub-only
 *   skipped: %(n_irrel)d irrelevant (glibc internals / ABI markers)
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
%(headers)s

#define SHIM(rt)      __attribute__((visibility("default"))) rt
#define SHIM_DATA(t)  __attribute__((visibility("default"))) t
#define SHIM_M(bits)  ((bits) == 64 ? ~0ULL : ((1ULL << (bits)) - 1ULL))

#define SHIM_FLOOR_RELEASE "%(floor_release)s"

/* x86-64 and every other 64-bit port use _STAT_VER_LINUX == 1. */
#ifndef SHIM_STAT_VER
#define SHIM_STAT_VER 1
#endif

/* Declared opaquely so the shim builds on a glibc too old to know the type.
   Only ever passed straight through to the kernel. */
struct mount_attr;

extern int __cxa_atexit(void (*)(void *), void *, void *);

/* strlen without depending on the real one being interposable. */
static size_t shim_strlen(const char *s)
{ const char *p = s; while (*p) p++; return (size_t)(p - s); }

/* Loud failure, naming the symbol. Deliberately not a return-0 stub:
   a driver that reaches here would otherwise corrupt state silently. */
__attribute__((noreturn))
static void shim_fatal(const char *sym, const char *why) {
	/* write(2) rather than fprintf: reachable from contexts where stdio
	   locks are held, and this path is already fatal. */
	static const char p1[] = "\n[cross-libc-dlopen] FATAL: ";
	static const char p2[] = "\n[cross-libc-dlopen] the bundled glibc " SHIM_FLOOR_RELEASE;
	static const char p3[] = " does not provide this symbol\n"
	                         "[cross-libc-dlopen] and no implementation exists for it. "
	                         "Set CROSS_LIBC_DLOPEN_RUNTIME=host to run\n"
	                         "[cross-libc-dlopen] against the host's own libc, "
	                         "which will have it.\n";
	(void)!write(2, p1, sizeof p1 - 1);
	(void)!write(2, sym, shim_strlen(sym));
	(void)!write(2, ": ", 2);
	(void)!write(2, why, shim_strlen(why));
	(void)!write(2, p2, sizeof p2 - 1);
	(void)!write(2, p3, sizeof p3 - 1);
	abort();
}
"""


def _proto_of(code, sym):
    """
    Extract a forward declaration from a generated definition.

    Bodies call each other (strlcat -> strlcpy, arc4random -> arc4random_buf)
    and the emission order is alphabetical, so every definition needs a
    prototype ahead of the block.  Data definitions get an extern instead.
    """
    m = re.search(r"^SHIM\((.*?)\)\s+" + re.escape(sym) + r"\s*\((.*?)\)\s*\{",
                  code, re.M | re.S)
    if m:
        return f"{m.group(1)} {sym}({m.group(2)});"
    m = re.search(r"^SHIM_DATA\((.*?)\)\s+" + re.escape(sym) + r"\b", code, re.M)
    if m:
        return f"extern {m.group(1)} {sym};"
    return None


def render(floor, target, gap, decided, args):
    """Emit forward-shim.c."""
    headers = set()
    n = {"implementable": 0, "forwardable": 0, "stub-only": 0, "irrelevant": 0}
    for sym, (kind, _why) in decided.items():
        n[kind] += 1
        if kind in ("implementable", "forwardable"):
            headers.update(IMPL[sym]["headers"])

    out = []
    hdr_block = "\n".join(f"#include {h}" for h in sorted(headers))
    out.append(PROLOGUE % dict(
        floor_name=floor["name"], floor_release=floor["release"],
        target_name=target["name"], target_release=target["release"],
        n_impl=n["implementable"], n_fwd=n["forwardable"],
        n_stub=n["stub-only"], n_irrel=n["irrelevant"], headers=hdr_block))

    impl = sorted(s for s, (k, _) in decided.items() if k == "implementable")
    stub = sorted(s for s, (k, _) in decided.items() if k == "stub-only")

    if impl:
        protos = [p for p in (_proto_of(IMPL[s]["code"], s) for s in impl) if p]
        out.append("\n/* ---- forward declarations (definitions are emitted "
                   "alphabetically and call each other) ---- */")
        out.extend(protos)
        out.append("\n/* ---------------- implementable ---------------- */\n")
        for s in impl:
            out.append(f"/* {s}: {decided[s][1]} */")
            out.append(IMPL[s]["code"].strip("\n"))
            out.append("")

    if stub:
        out.append("\n/* ---------------- stub-only: abort naming the symbol ---------------- */\n")
        out.append("/* Each stub is defined under a mangled C name and given the real\n"
                   "   symbol name with an asm label. Defining `crypt` as void(void)\n"
                   "   directly collides with the prototype <unistd.h> already made\n"
                   "   visible; the label sets the emitted symbol without ever\n"
                   "   declaring a conflicting C identifier. */\n")
        kinds = target.get("kinds", {})
        for s in stub:
            why = decided[s][1].replace("*/", "* /")
            k = kinds.get(s, {})
            out.append(f"/* {s}: {why} */")
            if k.get("type") == "OBJECT":
                # A data symbol must be data. A function here would hand the
                # caller code bytes to read as a value; zeroed storage of the
                # real size is at least well-defined.
                size = max(int(k.get("size") or 0), 1)
                out.append(f'SHIM_DATA(char) shim_stub_{s}[{size}] '
                           f'__asm__("{s}") __attribute__((aligned(16))) = {{ 0 }};')
            else:
                out.append(f'SHIM(void) shim_stub_{s}(void) __asm__("{s}");')
                out.append(f'SHIM(void) shim_stub_{s}(void) {{ shim_fatal("{s}", '
                           f'"not implementable over this glibc"); }}')
        out.append("")

    # Runtime guard: a shim generated for the wrong floor would interpose over
    # symbols the real libc already has. Detect and say so; do not pretend.
    names = impl + stub
    out.append("\n/* ---------------- stale-shim guard ---------------- */")
    out.append("/* If the bundled glibc was upgraded without regenerating this file we\n"
               "   would be interposing over symbols libc now provides. Detect that and\n"
               "   say so loudly under CROSS_LIBC_DLOPEN_DEBUG=1 rather than fail mutely. */")
    out.append("static const char *const shim_covered[] = {")
    for s in names:
        out.append(f'\t"{s}",')
    out.append("\tNULL\n};")
    out.append(r"""
__attribute__((visibility("default")))
const char *const *forward_shim_covered(void) { return shim_covered; }

__attribute__((visibility("default")))
const char *forward_shim_floor(void) { return SHIM_FLOOR_RELEASE; }
""")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--floor", required=True, help="inventory JSON of the runtime we bundle")
    ap.add_argument("--target", required=True, help="inventory JSON of a newer glibc")
    ap.add_argument("--out", help="write forward-shim.c here")
    ap.add_argument("--manifest", help="write the classification JSON here")
    ap.add_argument("--musl", help="inventory JSON of a musl libc. Its exports "
                                   "that the floor lacks are added to the gap: a "
                                   "musl-built host object can import any of them, "
                                   "and they are just as enumerable as the version "
                                   "gap (measured: 53 symbols)")
    ap.add_argument("--extra", nargs="*", default=["atexit", "at_quick_exit"],
                    help="symbols to cover even when no diff names them. atexit "
                         "is the standing case: glibc keeps it in the static "
                         "libc_nonshared.a at EVERY release, so it appears in no "
                         "version diff yet is absent from libc.so.6")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    floor = json.load(open(a.floor, encoding="utf-8"))
    target = json.load(open(a.target, encoding="utf-8"))
    floor_syms = set(floor["symbols"])

    gap = sorted(set(target["symbols"]) - floor_syms)
    tkinds = dict(target.get("kinds", {}))

    musl_only = []
    if a.musl:
        musl = json.load(open(a.musl, encoding="utf-8"))
        musl_only = sorted(set(musl["symbols"]) - floor_syms)
        # A musl-built host object binds these by name once its own libc edge
        # is dropped, so they are part of the same enumerable gap.
        for s in musl_only:
            if s not in gap:
                gap.append(s)
        for s, k in musl.get("kinds", {}).items():
            tkinds.setdefault(s, k)

    for e in a.extra:
        if e not in floor_syms and e not in gap:
            gap.append(e)
    gap.sort()

    decided = {s: classify(s, floor_syms, tkinds.get(s)) for s in gap}
    emitted = {s: v for s, v in decided.items() if v[0] != "irrelevant"}

    n = {}
    for k in ("implementable", "forwardable", "stub-only", "irrelevant"):
        n[k] = sum(1 for v in decided.values() if v[0] == k)

    if not a.quiet:
        print(f"floor  : {floor['name']} glibc {floor['release']} "
              f"({len(floor_syms)} symbols)")
        print(f"target : {target['name']} glibc {target['release']} "
              f"({len(target['symbols'])} symbols)")
        if musl_only:
            print(f"musl   : {len(musl_only)} symbols musl exports and the floor "
                  f"does not")
        print(f"gap    : {len(gap)} symbols the floor lacks")
        for k in ("implementable", "forwardable", "stub-only", "irrelevant"):
            print(f"   {k:14} {n[k]:4}")
        if emitted:
            print(f"emitting {len(emitted)} definitions")

    src = render(floor, target, gap, emitted, a)
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, "w", encoding="utf-8", newline="\n").write(src)
        if not a.quiet:
            print(f"wrote {a.out} ({len(src)} bytes)")

    manifest = {
        "generator": "tools/gen_forward_shim.py",
        "floor": {"name": floor["name"], "release": floor["release"],
                  "symbols": len(floor_syms)},
        "target": {"name": target["name"], "release": target["release"],
                   "symbols": len(target["symbols"])},
        "counts": n,
        "gap_total": len(gap),
        "musl_only": musl_only,
        "classification": {s: {"kind": k, "reason": w} for s, (k, w) in
                           sorted(decided.items())},
        "note": ("Covers only the enumerable gap. A symbol introduced after "
                 "this manifest was generated is NOT covered and cannot be -- "
                 "see REPORT.md. Design R (host-runtime switch) is the "
                 "forward-compatible path."),
    }
    if a.manifest:
        os.makedirs(os.path.dirname(os.path.abspath(a.manifest)), exist_ok=True)
        open(a.manifest, "w", encoding="utf-8", newline="\n").write(
            json.dumps(manifest, indent=1, sort_keys=True))
        if not a.quiet:
            print(f"wrote {a.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
