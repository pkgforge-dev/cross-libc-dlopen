/* T1.3 - T1.7, guest half -- the HOST DRIVER's side of the boundary.
 *
 * Built twice: once on Alpine, where it is a faithful musl-linked object of the
 * kind cross-libc-dlopen has to load, and once on the glibc floor as the control.
 * The musl build then has its libc.musl-x86_64.so.1 DT_NEEDED removed, which is
 * exactly what cross-libc-dlopen does, so every libc reference in it is resolved
 * from the loading process instead.
 *
 * The point of each entry point is to make a thing CROSS: memory allocated on
 * one side and released on the other, an errno set on one side and read on the
 * other, a FILE* opened on one side and written from the other, a mutex made on
 * one side and locked from the other. A size table alone would only prove the
 * headers disagree, which was never in doubt.
 *
 * Nothing here prints. The host half owns the report, and a guest that wrote to
 * stdout would be measuring stdout rather than using it.
 */
#include "abi-abi.h"

#include <stdlib.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT uint32_t abi_version(void) { return ABI_VIEW_VERSION; }

/* The filler is one inline function in abi-abi.h, compiled into both sides from
 * identical source, so the two columns of the report differ only because the
 * HEADERS differ. */
EXPORT void abi_fill(struct abi_view *v) { abi_view_fill(v); }

/* T1.3 -- allocator ownership crossing the boundary. */
EXPORT void *abi_alloc(uint64_t n) {
	void *p = malloc((size_t)n);
	if (p) memset(p, 0x5A, (size_t)n);
	return p;
}

EXPORT int abi_release(void *p) { free(p); return 0; }

/* T1.3b -- strdup, because the free() that matters is often one the caller
 * never sees written down. */
EXPORT char *abi_strdup(const char *s) { return strdup(s); }

/* T1.4 -- errno coherence. Fail HERE and report the value seen HERE; the host
 * reads its own errno immediately afterwards and compares. Two sides reaching
 * different __errno_location report different values. */
EXPORT int abi_errno_after_failing_open(void) {
	errno = 0;
	int fd = open("/nonexistent-directory-for-abi-probe/x", O_RDONLY);
	if (fd >= 0) { close(fd); return -1; }
	return errno;
}

/* T1.5 -- a FILE* opened by the host, written from here. glibc's FILE is 216
 * bytes with a public layout and musl's is neither, so only one of them can be
 * right about the object. */
EXPORT int abi_write_file(void *fp, const char *s) {
	FILE *f = (FILE *)fp;
	if (fputs(s, f) < 0) return -1;
	if (fflush(f) != 0) return -2;
	return (int)strlen(s);
}

/* T1.6 -- a mutex made by the host, locked from here. */
EXPORT int abi_lock_unlock(void *mtx) {
	pthread_mutex_t *m = (pthread_mutex_t *)mtx;
	int r = pthread_mutex_lock(m);
	if (r) return r;
	return pthread_mutex_unlock(m);
}

/* T1.6b -- and the reverse: a mutex made HERE, sized by THESE headers, handed
 * back for the host to lock. */
EXPORT void *abi_new_mutex(void) {
	pthread_mutex_t *m = malloc(sizeof *m);
	if (!m) return NULL;
	if (pthread_mutex_init(m, NULL) != 0) { free(m); return NULL; }
	return m;
}

/* T1.6c -- signalling a condition variable the host created and is waiting on.
 * This is the entry point the version-binding trap lands on: an unversioned
 * pthread_cond_signal reaches glibc's pre-2003 implementation, which reads the
 * first eight bytes of the object as a pointer to a different structure. */
EXPORT int abi_cond_signal(void *cond, void *mtx) {
	pthread_mutex_t *m = (pthread_mutex_t *)mtx;
	pthread_cond_t *c = (pthread_cond_t *)cond;
	int r = pthread_mutex_lock(m);
	if (r) return r;
	r = pthread_cond_signal(c);
	pthread_mutex_unlock(m);
	return r;
}

/* T1.7 -- one function per hazard, actually CALLED, so the divergent struct is
 * written and read across the boundary rather than merely sized. The host
 * passes storage it allocated with ITS headers. */
EXPORT int abi_regexec_into(void *pmatch, uint64_t nmatch, const char *pat,
                            const char *text) {
	regex_t re;
	if (regcomp(&re, pat, REG_EXTENDED) != 0) return -1;
	int r = regexec(&re, text, (size_t)nmatch, (regmatch_t *)pmatch, 0);
	regfree(&re);
	return r;
}

EXPORT int abi_getrusage_into(void *ru) {
	return getrusage(RUSAGE_SELF, (struct rusage *)ru);
}

EXPORT int abi_sched_getparam_into(void *sp) {
	return sched_getparam(0, (struct sched_param *)sp);
}

EXPORT int abi_stat_into(const char *path, void *st) {
	return stat(path, (struct stat *)st);
}

/* T1.7c -- the direction that actually breaks.
 *
 * Everything above passes storage the HOST allocated, so glibc's implementation
 * writes glibc's layout into glibc-sized memory and nothing can overrun. That
 * is not the hazard. The hazard is a guest that allocates a struct with ITS
 * headers, hands it to glibc, and then READS IT BACK at its own offsets --
 * which is what any real library does with regexec, nftw or getrusage. Nothing
 * crashes; the numbers are simply wrong.
 *
 * Each of these returns what the guest believes it read. The host computes the
 * same thing for itself, and the two either agree or name a live hazard.
 */
EXPORT int64_t abi_own_regexec_end(const char *pat, const char *text) {
	regmatch_t m[8];
	regex_t re;
	memset(m, 0, sizeof m);
	if (regcomp(&re, pat, REG_EXTENDED) != 0) return -1;
	int r = regexec(&re, text, 8, m, 0);
	regfree(&re);
	if (r != 0) return -2;
	return (int64_t)m[0].rm_eo;      /* read at THIS side's stride */
}

EXPORT int64_t abi_own_rusage_maxrss(void) {
	struct rusage ru;
	memset(&ru, 0, sizeof ru);
	if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
	return (int64_t)ru.ru_maxrss;    /* read at THIS side's offset */
}

static int abi_ftw_dirs;
static int abi_ftw_cb(const char *p, const struct stat *sb, int typeflag,
                      struct FTW *f) {
	(void)p; (void)sb; (void)f;
	if (typeflag == FTW_D) abi_ftw_dirs++;   /* THIS side's value of FTW_D */
	return 0;
}

EXPORT int abi_nftw_count_dirs(const char *path) {
	abi_ftw_dirs = 0;
	if (nftw(path, abi_ftw_cb, 8, 0) != 0) return -1;
	return abi_ftw_dirs;
}
