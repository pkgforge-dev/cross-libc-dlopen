/* Unversioned-reference compatibility forwarders.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * cross-libc-dlopen.c makes a host object loadable against our libc by removing
 * its symbol version requirements, and a musl-built object never had any to
 * begin with.  Either way the object's references become plain names.
 *
 * For nearly every symbol that is exactly right.  For the handful glibc still
 * exports at an obsolete version it is a trap, because an unversioned
 * relocation does NOT pick the default definition:
 *
 *     pthread_cond_init@GLIBC_2.2.5   __pthread_cond_init_2_0, whose entire
 *                                     body is `if (attr) return EINVAL;`
 *     pthread_cond_init@@GLIBC_2.3.2  the real one
 *
 * Measured (REPORT.md T3.2, E22): a stripped or musl-built object calling
 * pthread_cond_init with an attribute gets EINVAL.  In Mesa that surfaces as
 * u_cnd_monotonic_init -> thrd_error -> wsi_display_init_wsi ->
 * VK_ERROR_OUT_OF_HOST_MEMORY -> vkEnumeratePhysicalDevices reports zero
 * devices.  Two years of "the driver loads but nothing works" is this.
 *
 * THE FIX
 * -------
 * The preload is ahead of libc in the global lookup scope, so an unversioned
 * definition here wins every unversioned reference in the process.  Each one
 * below then forwards to the DEFAULT definition, which is what the reference
 * should have reached.
 *
 * Finding that definition is the part worth being careful about.  dlsym is not
 * a reliable answer: measured in E27, dlsym(RTLD_NEXT, "pthread_cond_init")
 * returns the OBSOLETE definition on glibc 2.31 and the default one on 2.41,
 * because the RTLD_NEXT path did not always carry DL_LOOKUP_RETURN_NEWEST.
 * So the version NAME is read out of the defining object's own
 * .gnu.version_d, the entry without the hidden bit, and handed to dlvsym,
 * which is correct on every glibc measured.  No version string is hardcoded
 * anywhere, so this stays right across releases.
 *
 * WHICH SYMBOLS
 * -------------
 * tools/version_traps.py computes the set mechanically from a libc: a name
 * defined at two or more versions whose st_value DIFFERS.  Same address at
 * several versions is re-versioning, not an ABI change. The glibc 2.34
 * libpthread merge does that to 191 symbols and none of them matter.
 *
 *     python3 tools/version_traps.py /lib/x86_64-linux-gnu/libc.so.6
 *     python3 tools/version_traps.py <libc> --check src/version-compat.c
 *
 * The --check mode fails if a libc has a trap this file does not cover, so a
 * future glibc cannot introduce one silently.  Deliberate exclusions are
 * listed in the exclusions block below and honoured by the checker.
 *
 * COST AND BLAST RADIUS
 * ---------------------
 * These definitions are process-wide: a bundled library's own
 * pthread_cond_init@GLIBC_2.3.2 reference also lands here, because glibc lets
 * an unversioned definition satisfy a versioned reference (that is how
 * LD_PRELOAD interposition has always worked).  It then forwards to the same
 * default version it would have reached directly, so behaviour is unchanged
 * and the cost is one indirect call.  The one case this would get wrong is an
 * object that genuinely wants an obsolete version, such as glibc 2.2.5-era condition
 * variables, 2003 and earlier.  Nothing that ships in an AppImage does.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef _LARGEFILE64_SOURCE
#define _LARGEFILE64_SOURCE
#endif

#include <aio.h>
#include <dlfcn.h>
#include <ftw.h>
#include <glob.h>
#include <pthread.h>
#include <regex.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "cld-symver.h"
#include "cld-env.h"

#define VC_VISIBLE __attribute__((visibility("default")))

/* regexec's match array is a VLA parameter in glibc's own declaration, and
 * gcc 11+ warns under -Wall at any other spelling.  regex.h's helper macros are
 * not reliably still defined after the header (glibc 2.31 leaves _REGEX_NELTS
 * looking like a function call), so re-provide them when absent. */
#ifndef _Restrict_arr_
#define _Restrict_arr_
#endif
#ifndef _REGEX_NELTS
#define _REGEX_NELTS(n) n
#endif

/* Deliberate exclusions, read by tools/version_traps.py --check:
 *
 * VC_EXCLUDED memcpy        both definitions satisfy the memcpy contract, so
 *                           binding to either is correct.  The 2.14 split was
 *                           about direction of copy for OVERLAPPING regions,
 *                           which memcpy never promised anything about; a
 *                           conforming caller cannot tell them apart.  E24
 *                           checks that byte-for-byte over 4096 size and
 *                           alignment combinations rather than taking the
 *                           history's word for it.  Interposing every memcpy
 *                           in a rendering process, texture uploads included,
 *                           to fix nothing is not a trade worth making.
 * VC_EXCLUDED sys_nerr      data objects, not functions: a forwarder cannot
 * VC_EXCLUDED _sys_nerr     alias them.  From glibc 2.32 neither has a default
 *                           version at all, so an unversioned reference fails
 *                           loudly as an undefined symbol rather than binding
 *                           to the wrong copy.  Loud is acceptable.
 */

__attribute__((noreturn))
static void vc_fatal(const char *sym) {
	/* Cannot happen: every name here is one this libc exports.  If it does,
	 * say which symbol rather than dying in an indirect call through NULL. */
	fprintf(stderr, " [cross-libc-dlopen.so] >> version-compat: %s did not resolve\n", sym);
	abort();
}

/* The definition an unversioned reference SHOULD have reached.
 *
 * dlvsym with the version name read out of the defining object's ELF is the
 * correct path, and the only one that behaves the same on every glibc. The
 * dlsym fallback covers a provider whose tables cannot be read: it degrades to
 * exactly today's behaviour rather than to a NULL call, so the forwarder is
 * never worse than not being there. */
static void *vc_resolve(const char *sym) {
	/* cld_default_version_of() opens and parses a file, so it allocates. If
	 * anything on that path ever calls a symbol forwarded from this file, the
	 * second call would resolve through here again and recurse until the stack
	 * is gone. Nothing does today, because glibc's allocator uses mutexes, not
	 * condition variables, and does not reach these through the PLT. But a
	 * guard costs one thread-local byte and turns an unbounded recursion into
	 * a slightly worse answer. */
	static __thread int busy;
	char ver[64];
	void *p = NULL;
	int versioned = 0;

	if (!busy) {
		busy = 1;
		versioned = cld_default_version_of(sym, ver, sizeof(ver));
		busy = 0;
	}

	if (versioned)
		p = dlvsym(RTLD_NEXT, (char *)sym, ver);
	if (!p)
		p = dlsym(RTLD_NEXT, sym);

	if (cld_getenv("CROSS_LIBC_DLOPEN_DEBUG", NULL))
		fprintf(stderr, " [cross-libc-dlopen.so] >> version-compat: %s@%s -> %p\n",
		        sym, versioned ? ver : "(unversioned)", p);
	return p;
}

/* One resolved target per symbol.  Lazy rather than constructor-time on
 * purpose: another preload's constructor can call into these before ours would
 * have run, and a NULL jump there is an unattributable crash. */
#define VC_SLOT(sym)                                                          \
	static void *vc_slot_##sym;                                           \
	static void *vc_get_##sym(void) {                                     \
		void *p = __atomic_load_n(&vc_slot_##sym, __ATOMIC_ACQUIRE);  \
		if (__builtin_expect(p == NULL, 0)) {                         \
			p = vc_resolve(#sym);                                 \
			if (!p) vc_fatal(#sym);                               \
			__atomic_store_n(&vc_slot_##sym, p, __ATOMIC_RELEASE);\
		}                                                             \
		return p;                                                     \
	}

/* __typeof__ of the function being defined is the header's prototype, so the
 * call through the pointer cannot drift from the definition, and the
 * definition cannot drift from libc's declaration. Two compile-time checks for
 * free; no signature is written out twice anywhere in this file. */
#define VC_CALL(sym) ((__typeof__(sym) *)vc_get_##sym())

/* --- condition variables: the ones that broke Mesa ---------------------- */

VC_SLOT(pthread_cond_init)
VC_VISIBLE int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) {
	return VC_CALL(pthread_cond_init)(c, a);
}

VC_SLOT(pthread_cond_destroy)
VC_VISIBLE int pthread_cond_destroy(pthread_cond_t *c) {
	return VC_CALL(pthread_cond_destroy)(c);
}

VC_SLOT(pthread_cond_signal)
VC_VISIBLE int pthread_cond_signal(pthread_cond_t *c) {
	return VC_CALL(pthread_cond_signal)(c);
}

VC_SLOT(pthread_cond_broadcast)
VC_VISIBLE int pthread_cond_broadcast(pthread_cond_t *c) {
	return VC_CALL(pthread_cond_broadcast)(c);
}

VC_SLOT(pthread_cond_wait)
VC_VISIBLE int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
	return VC_CALL(pthread_cond_wait)(c, m);
}

VC_SLOT(pthread_cond_timedwait)
VC_VISIBLE int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m,
                                      const struct timespec *t) {
	return VC_CALL(pthread_cond_timedwait)(c, m, t);
}

/* --- CPU affinity: the old versions take no size argument --------------- */

VC_SLOT(sched_getaffinity)
VC_VISIBLE int sched_getaffinity(pid_t pid, size_t n, cpu_set_t *set) {
	return VC_CALL(sched_getaffinity)(pid, n, set);
}

VC_SLOT(sched_setaffinity)
VC_VISIBLE int sched_setaffinity(pid_t pid, size_t n, const cpu_set_t *set) {
	return VC_CALL(sched_setaffinity)(pid, n, set);
}

VC_SLOT(pthread_getaffinity_np)
VC_VISIBLE int pthread_getaffinity_np(pthread_t th, size_t n, cpu_set_t *set) {
	return VC_CALL(pthread_getaffinity_np)(th, n, set);
}

VC_SLOT(pthread_setaffinity_np)
VC_VISIBLE int pthread_setaffinity_np(pthread_t th, size_t n, const cpu_set_t *set) {
	return VC_CALL(pthread_setaffinity_np)(th, n, set);
}

VC_SLOT(pthread_attr_getaffinity_np)
VC_VISIBLE int pthread_attr_getaffinity_np(const pthread_attr_t *at, size_t n, cpu_set_t *set) {
	return VC_CALL(pthread_attr_getaffinity_np)(at, n, set);
}

VC_SLOT(pthread_attr_setaffinity_np)
VC_VISIBLE int pthread_attr_setaffinity_np(pthread_attr_t *at, size_t n, const cpu_set_t *set) {
	return VC_CALL(pthread_attr_setaffinity_np)(at, n, set);
}

VC_SLOT(pthread_kill)
VC_VISIBLE int pthread_kill(pthread_t th, int sig) {
	return VC_CALL(pthread_kill)(th, sig);
}

/* --- POSIX timers: timer_t changed from int to pointer ------------------ */

VC_SLOT(timer_create)
VC_VISIBLE int timer_create(clockid_t clk, struct sigevent *ev, timer_t *out) {
	return VC_CALL(timer_create)(clk, ev, out);
}

VC_SLOT(timer_delete)
VC_VISIBLE int timer_delete(timer_t t) {
	return VC_CALL(timer_delete)(t);
}

VC_SLOT(timer_settime)
VC_VISIBLE int timer_settime(timer_t t, int flags, const struct itimerspec *v,
                             struct itimerspec *old) {
	return VC_CALL(timer_settime)(t, flags, v, old);
}

VC_SLOT(timer_gettime)
VC_VISIBLE int timer_gettime(timer_t t, struct itimerspec *v) {
	return VC_CALL(timer_gettime)(t, v);
}

VC_SLOT(timer_getoverrun)
VC_VISIBLE int timer_getoverrun(timer_t t) {
	return VC_CALL(timer_getoverrun)(t);
}

/* --- struct-layout and NULL-argument changes ---------------------------- */

VC_SLOT(realpath)
VC_VISIBLE char *realpath(const char *name, char *resolved) {
	/* GLIBC_2.2.5 rejects resolved == NULL, which is how everything calls
	 * it today. */
	return VC_CALL(realpath)(name, resolved);
}

VC_SLOT(glob)
VC_VISIBLE int glob(const char *pat, int flags, int (*errfn)(const char *, int), glob_t *g) {
	/* glob_t grew fields for GLOB_ALTDIRFUNC; the old one writes a shorter
	 * struct than the caller declared. */
	return VC_CALL(glob)(pat, flags, errfn, g);
}

VC_SLOT(glob64)
VC_VISIBLE int glob64(const char *pat, int flags, int (*errfn)(const char *, int), glob64_t *g) {
	return VC_CALL(glob64)(pat, flags, errfn, g);
}

VC_SLOT(nftw)
VC_VISIBLE int nftw(const char *path, __nftw_func_t fn, int fd_limit, int flags) {
	/* FTW_* constants were renumbered; the old one dispatches on the wrong
	 * branch rather than failing. */
	return VC_CALL(nftw)(path, fn, fd_limit, flags);
}

VC_SLOT(nftw64)
VC_VISIBLE int nftw64(const char *path, __nftw64_func_t fn, int fd_limit, int flags) {
	return VC_CALL(nftw64)(path, fn, fd_limit, flags);
}

VC_SLOT(regexec)
VC_VISIBLE int regexec(const regex_t *__restrict re, const char *__restrict s, size_t n,
                       regmatch_t m[_Restrict_arr_ _REGEX_NELTS(n)], int flags) {
	return VC_CALL(regexec)(re, s, n, m, flags);
}

VC_SLOT(fmemopen)
VC_VISIBLE FILE *fmemopen(void *buf, size_t size, const char *mode) {
	return VC_CALL(fmemopen)(buf, size, mode);
}

VC_SLOT(posix_spawn)
VC_VISIBLE int posix_spawn(pid_t *pid, const char *path,
                           const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *at,
                           char *const argv[], char *const envp[]) {
	return VC_CALL(posix_spawn)(pid, path, fa, at, argv, envp);
}

VC_SLOT(posix_spawnp)
VC_VISIBLE int posix_spawnp(pid_t *pid, const char *file,
                            const posix_spawn_file_actions_t *fa,
                            const posix_spawnattr_t *at,
                            char *const argv[], char *const envp[]) {
	return VC_CALL(posix_spawnp)(pid, file, fa, at, argv, envp);
}

VC_SLOT(lio_listio)
VC_VISIBLE int lio_listio(int mode, struct aiocb *const list[], int n,
                          struct sigevent *ev) {
	return VC_CALL(lio_listio)(mode, list, n, ev);
}

VC_SLOT(lio_listio64)
VC_VISIBLE int lio_listio64(int mode, struct aiocb64 *const list[], int n,
                            struct sigevent *ev) {
	return VC_CALL(lio_listio64)(mode, list, n, ev);
}

/* --- terminal line speed: glibc 2.42 added arbitrary baud rates ------- */
/*
 * Found by `make traps` on glibc 2.42, not by reasoning: the GLIBC_2.2.5
 * definitions speak the old Bnnn-encoded speed_t and the 2.42 ones take a real
 * number of bits per second. Nothing in a graphics driver closure calls these,
 * which is exactly why an audit that enumerates rather than guesses is worth
 * having: the set grew under a glibc newer than any this was developed on.
 */

VC_SLOT(cfgetispeed)
VC_VISIBLE speed_t cfgetispeed(const struct termios *t) {
	return VC_CALL(cfgetispeed)(t);
}

VC_SLOT(cfgetospeed)
VC_VISIBLE speed_t cfgetospeed(const struct termios *t) {
	return VC_CALL(cfgetospeed)(t);
}

VC_SLOT(cfsetispeed)
VC_VISIBLE int cfsetispeed(struct termios *t, speed_t speed) {
	return VC_CALL(cfsetispeed)(t, speed);
}

VC_SLOT(cfsetospeed)
VC_VISIBLE int cfsetospeed(struct termios *t, speed_t speed) {
	return VC_CALL(cfsetospeed)(t, speed);
}

VC_SLOT(cfsetspeed)
VC_VISIBLE int cfsetspeed(struct termios *t, speed_t speed) {
	return VC_CALL(cfsetspeed)(t, speed);
}

VC_SLOT(quick_exit)
VC_VISIBLE __attribute__((noreturn)) void quick_exit(int status) {
	VC_CALL(quick_exit)(status);
	abort();  /* not reached; the real one does not return */
}
