/* T1.3 - T1.7, host half -- the AppImage's side of the boundary.
 *
 * REPORT.md carried these five as SKIPPED and UNVERIFIED for the whole project.
 * They mattered because a host driver built against a different libc might
 * share a struct, an allocation, an errno or a FILE with the process, and if
 * the two sides disagree about any of them the damage is silent. They were once
 * called the most likely home of the rendering failure; they were not (section
 * 4.1), which lowered their priority without making them any less real.
 *
 * Against a guest library built by the OTHER libc, with its libc edge dropped:
 *
 *   T1.3  memory allocated in the guest is freed here, and the reverse
 *   T1.4  an errno set inside the guest is read here, in the same thread
 *   T1.5  a FILE* opened here is written from the guest
 *   T1.6  a mutex made here is locked there, a mutex made there is locked
 *         here, and a condition variable made here is signalled from there.
 *         ⚠ The second of those is not attempted, and is reported as a live
 *         hazard, when the two pthread_mutex_t sizes differ at all: the guest
 *         allocates its own size and the init it reaches writes ours, so the
 *         overflow is inside the guest. aarch64 is such a pair, x86-64 is not
 *   T1.7  every struct size and constant the two sides could disagree about,
 *         printed side by side -- and then the divergent structs actually
 *         WRITTEN by the guest into storage this side allocated, behind a
 *         guard band, because an overrun that only happens on success is the
 *         most misleading result available (section 5)
 *
 * The size table is ground truth, not a verdict: a musl guest is EXPECTED to
 * disagree about several of them. The verdict is whether anything crosses
 * wrongly once every reference in the guest resolves to this process's libc.
 *
 *      tests/abi-host <guest.so> [expected-libc]
 *
 * The optional second argument is the libc the guest must have been built by.
 * The control build and the real build export the same names and differ only in
 * that, so without it a mixed-up build would pass while measuring glibc against
 * itself.
 */
#include "abi-abi.h"

#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static int fails, checks;

static void ok(int cond, const char *what, const char *detail) {
	checks++;
	if (!cond) fails++;
	printf("    %-4s %-36s %s\n", cond ? "ok" : "FAIL", what, detail ? detail : "");
}

/* Where an address really lives. The address comparison alone can mislead: an
 * EXECUTABLE that takes the address of a libc function gets its own PLT entry
 * as the canonical value, so the two columns may differ for a linking reason
 * and not a libc one. Printing the file and symbol behind each address is what
 * separates those two explanations, so this prints them always rather than only
 * when something looks wrong. */
static const char *whereis(uint64_t addr, char *buf, size_t n) {
	Dl_info di;
	if (!addr || !dladdr((void *)(uintptr_t)addr, &di) || !di.dli_fname) {
		snprintf(buf, n, "0x%llx (unresolved)", (unsigned long long)addr);
		return buf;
	}
	const char *slash = strrchr(di.dli_fname, '/');
	snprintf(buf, n, "%s:%s", slash ? slash + 1 : di.dli_fname,
	         di.dli_sname ? di.dli_sname : "(no symbol)");
	return buf;
}

/* One implementation for both sides? Equal addresses settle it outright.
 * Otherwise fall back to the file each address lives in, which is the question
 * actually being asked: PLT canonicalisation moves the address, never the
 * implementation. */
static void same_impl(const struct abi_view *g, uint64_t ga, uint64_t ha,
                      const char *what) {
	char gb[160], hb[160], detail[400];
	Dl_info gd, hd;
	whereis(ga, gb, sizeof gb);
	whereis(ha, hb, sizeof hb);
	int same = (ga == ha);
	if (!same
	    && dladdr((void *)(uintptr_t)ga, &gd) && dladdr((void *)(uintptr_t)ha, &hd)
	    && gd.dli_fname && hd.dli_fname && strcmp(gd.dli_fname, hd.dli_fname) == 0)
		same = 1;
	snprintf(detail, sizeof detail, "guest(%s)=%s  host=%s", g->libc, gb, hb);
	ok(same, what, detail);
}

static void row(const char *name, unsigned long long guest, unsigned long long host) {
	printf("    %-22s guest=%-8llu host=%-8llu %s\n", name, guest, host,
	       guest == host ? "" : "<-- DIVERGES");
}

static void srow(const char *name, long long guest, long long host) {
	printf("    %-22s guest=%-8lld host=%-8lld %s\n", name, guest, host,
	       guest == host ? "" : "<-- DIVERGES");
}

/* The host's own nftw walk, written the same way the guest's is, so the two
 * counts differ only because the two FTW_D constants do. */
static int host_ftw_dirs;
static int host_ftw_cb(const char *p, const struct stat *sb, int typeflag,
                       struct FTW *f) {
	(void)p; (void)sb; (void)f;
	if (typeflag == FTW_D) host_ftw_dirs++;
	return 0;
}

static int guard_intact(const unsigned char *g, size_t n) {
	for (size_t i = 0; i < n; i++)
		if (g[i] != 0xC3) return 0;
	return 1;
}

struct waitctx {
	pthread_mutex_t m;
	pthread_cond_t c;
	int entered;                       /* the waiter is inside the wait */
	int fired;
	int rc;
};

/* `entered` is not decoration. Without it the main thread can set `fired`
 * before this one reaches the wait, the loop never runs, rc keeps its initial
 * value, and the case reports a failure that is really a scheduling race. It
 * is set under the mutex and the wait releases the mutex atomically, so once
 * the main thread can take the lock this thread is provably waiting. */
static void *waiter(void *arg) {
	struct waitctx *w = arg;
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_sec += 5;                    /* bounded: a broken condvar must not hang */
	pthread_mutex_lock(&w->m);
	w->entered = 1;
	while (!w->fired) {
		w->rc = pthread_cond_timedwait(&w->c, &w->m, &ts);
		if (w->rc) break;
	}
	pthread_mutex_unlock(&w->m);
	return NULL;
}

#define SYM(var, name)                                                        \
	do {                                                                      \
		dlerror();                                                            \
		*(void **)(&var) = dlsym(h, name);                                    \
		if (!var) { printf("FAILED: guest has no %s\n", name); return 2; }     \
	} while (0)

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc < 2) { printf("usage: abi-host <guest.so> [expected-libc]\n"); return 2; }

	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) { printf("FAILED: dlopen: %s\n", dlerror()); return 2; }

	uint32_t (*g_version)(void);
	void (*g_fill)(struct abi_view *);
	void *(*g_alloc)(uint64_t);
	int (*g_release)(void *);
	char *(*g_strdup)(const char *);
	int (*g_errno)(void);
	int (*g_write)(void *, const char *);
	int (*g_locku)(void *);
	void *(*g_newmtx)(void);
	int (*g_signal)(void *, void *);
	int (*g_regexec)(void *, uint64_t, const char *, const char *);
	int (*g_rusage)(void *);
	int (*g_schedp)(void *);
	int (*g_stat)(const char *, void *);

	SYM(g_version, "abi_version");
	SYM(g_fill,    "abi_fill");
	SYM(g_alloc,   "abi_alloc");
	SYM(g_release, "abi_release");
	SYM(g_strdup,  "abi_strdup");
	SYM(g_errno,   "abi_errno_after_failing_open");
	SYM(g_write,   "abi_write_file");
	SYM(g_locku,   "abi_lock_unlock");
	SYM(g_newmtx,  "abi_new_mutex");
	SYM(g_signal,  "abi_cond_signal");
	SYM(g_regexec, "abi_regexec_into");
	SYM(g_rusage,  "abi_getrusage_into");
	SYM(g_schedp,  "abi_sched_getparam_into");
	SYM(g_stat,    "abi_stat_into");

	if (g_version() != ABI_VIEW_VERSION) {
		printf("FAILED: guest speaks abi_view v%u, this host speaks v%u -- the\n"
		       "        table would be misread field for field\n",
		       g_version(), ABI_VIEW_VERSION);
		return 2;
	}

	struct abi_view gv, hv;
	g_fill(&gv);
	abi_view_fill(&hv);

	printf("  guest %s built by %s; host built by %s\n", argv[1], gv.libc, hv.libc);
	if (argc > 2 && strcmp(gv.libc, argv[2]) != 0) {
		printf("FAILED: expected a guest built by %s, got one built by %s.\n"
		       "        Both builds export the same names, so this would\n"
		       "        otherwise pass while measuring glibc against itself.\n",
		       argv[2], gv.libc);
		return 2;
	}

	printf("\n  T1.7a -- what the two sets of headers disagree about\n");
	printf("    (sizes first, then the offsets a size table cannot speak for)\n");
	row("regmatch_t",         gv.sz_regmatch_t,      hv.sz_regmatch_t);
	row("regex_t",            gv.sz_regex_t,         hv.sz_regex_t);
	row("struct rusage",      gv.sz_rusage,          hv.sz_rusage);
	row("struct sched_param", gv.sz_sched_param,     hv.sz_sched_param);
	row("ucontext_t",         gv.sz_ucontext_t,      hv.sz_ucontext_t);
	row("jmp_buf",            gv.sz_jmp_buf,         hv.sz_jmp_buf);
	row("sigset_t",           gv.sz_sigset_t,        hv.sz_sigset_t);
	row("glob_t",             gv.sz_glob_t,          hv.sz_glob_t);
	row("pthread_mutex_t",    gv.sz_pthread_mutex_t, hv.sz_pthread_mutex_t);
	row("pthread_cond_t",     gv.sz_pthread_cond_t,  hv.sz_pthread_cond_t);
	row("pthread_attr_t",     gv.sz_pthread_attr_t,  hv.sz_pthread_attr_t);
	row("struct dirent",      gv.sz_dirent,          hv.sz_dirent);
	row("struct stat",        gv.sz_stat,            hv.sz_stat);
	srow("FTW_D",             gv.v_FTW_D,            hv.v_FTW_D);
	srow("FTW_DNR",           gv.v_FTW_DNR,          hv.v_FTW_DNR);
	srow("FTW_DP",            gv.v_FTW_DP,           hv.v_FTW_DP);
	srow("FTW_F",             gv.v_FTW_F,            hv.v_FTW_F);
	srow("FTW_NS",            gv.v_FTW_NS,           hv.v_FTW_NS);
	srow("FTW_SL",            gv.v_FTW_SL,           hv.v_FTW_SL);
	srow("FTW_SLN",           gv.v_FTW_SLN,          hv.v_FTW_SLN);
	srow("O_LARGEFILE",       gv.v_O_LARGEFILE,      hv.v_O_LARGEFILE);
	srow("EWOULDBLOCK",       gv.v_EWOULDBLOCK,      hv.v_EWOULDBLOCK);
	srow("SIG_BLOCK",         gv.v_SIG_BLOCK,        hv.v_SIG_BLOCK);
	row("sizeof regoff_t",       gv.sz_regoff_t,        hv.sz_regoff_t);
	row("off rusage.ru_maxrss",  gv.off_rusage_maxrss,  hv.off_rusage_maxrss);
	row("off rusage.ru_nivcsw",  gv.off_rusage_nivcsw,  hv.off_rusage_nivcsw);
	row("off stat.st_mode",      gv.off_stat_mode,      hv.off_stat_mode);
	row("off stat.st_size",      gv.off_stat_size,      hv.off_stat_size);
	row("off dirent.d_name",     gv.off_dirent_name,    hv.off_dirent_name);
	row("off sched.priority",    gv.off_sched_priority, hv.off_sched_priority);

	printf("\n  which implementation each side reaches\n");
	same_impl(&gv, gv.addr_malloc, hv.addr_malloc, "malloc");
	same_impl(&gv, gv.addr_free, hv.addr_free, "free");
	same_impl(&gv, gv.addr_memcpy, hv.addr_memcpy, "memcpy");
	same_impl(&gv, gv.addr_errno_location, hv.addr_errno_location, "__errno_location");
	same_impl(&gv, gv.addr_pthread_mutex_lock, hv.addr_pthread_mutex_lock,
	          "pthread_mutex_lock");
	{
		/* stdout is a pointer VARIABLE; both sides carry its value, which is
		 * the address of the FILE object itself, so this one is an exact
		 * comparison with no linking caveat. */
		char detail[200];
		snprintf(detail, sizeof detail, "guest FILE*=0x%llx host FILE*=0x%llx",
		         (unsigned long long)gv.addr_stdout, (unsigned long long)hv.addr_stdout);
		ok(gv.addr_stdout == hv.addr_stdout, "stdout: one FILE object", detail);
	}

	printf("\n  T1.3 -- allocator ownership across the boundary\n");
	{
		char detail[96];
		void *p = g_alloc(4096);
		ok(p != NULL, "guest malloc returned memory", NULL);
		if (p) {
			int intact = 1;
			for (int i = 0; i < 4096; i++)
				if (((unsigned char *)p)[i] != 0x5A) { intact = 0; break; }
			ok(intact, "guest wrote all 4096 bytes of it", NULL);
			free(p);                   /* HOST frees GUEST memory */
			ok(1, "host free() of guest malloc()", "returned");
		}
		void *q = malloc(4096);
		if (q) memset(q, 0xA5, 4096);
		int r = q ? g_release(q) : -1; /* GUEST frees HOST memory */
		snprintf(detail, sizeof detail, "returned %d", r);
		ok(r == 0, "guest free() of host malloc()", detail);

		char *s = g_strdup("crossing");
		ok(s && strcmp(s, "crossing") == 0, "guest strdup readable here", s);
		free(s);
		ok(1, "host free() of guest strdup()", "returned");
	}

	printf("\n  T1.4 -- errno coherence\n");
	{
		char detail[96];
		errno = 0;
		int seen_there = g_errno();
		int seen_here = errno;         /* read FIRST, before anything clobbers it */
		snprintf(detail, sizeof detail, "guest saw %d, host sees %d",
		         seen_there, seen_here);
		ok(seen_there == ENOENT, "guest's failing open set ENOENT", detail);
		ok(seen_there == seen_here, "one errno location for both sides", detail);
	}

	printf("\n  T1.5 -- a FILE* opened here, written there\n");
	{
		char detail[160], buf[64] = { 0 };
		FILE *f = tmpfile();
		if (!f) {
			ok(0, "tmpfile()", strerror(errno));
		} else {
			const char *msg = "written by the guest\n";
			int w = g_write(f, msg);
			snprintf(detail, sizeof detail, "guest fputs returned %d", w);
			ok(w == (int)strlen(msg), "guest wrote into the host's FILE", detail);
			rewind(f);
			char *got = fgets(buf, sizeof buf, f);
			ok(got && strcmp(buf, msg) == 0, "host reads back what the guest wrote",
			   got ? buf : "(nothing)");
			fclose(f);
		}
	}

	printf("\n  T1.6 -- mutex and condition variable across the boundary\n");
	{
		char detail[128];
		pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
		int r = g_locku(&m);
		snprintf(detail, sizeof detail, "returned %d", r);
		ok(r == 0, "guest locked+unlocked a host mutex", detail);
		r = pthread_mutex_trylock(&m);
		ok(r == 0, "and left it unlocked", NULL);
		if (r == 0) pthread_mutex_unlock(&m);

		/* ⛔ THE CALL ITSELF IS THE OUT-OF-BOUNDS WRITE, so the guard is around
		 * the CALL and not around what is done with the result.
		 *
		 * abi_new_mutex() does `malloc(sizeof *m)` with the GUEST's
		 * pthread_mutex_t and then pthread_mutex_init() on it. That init is
		 * glibc's, because making every reference in the guest resolve to this
		 * process's libc is the entire point of the thing under test. So on a
		 * pair whose sizes differ the guest allocates its own size and glibc
		 * writes ours into it, and the overflow happens inside the guest before
		 * anything crosses back. On aarch64 that is 40 against 48: eight bytes
		 * into the allocator's next chunk header, and the free() below is
		 * merely where glibc notices, with "malloc(): invalid size (unsorted)"
		 * and SIGABRT.
		 *
		 * ⚠ MEASURED, AND THE FIRST VERSION OF THIS GUARD WAS IN THE WRONG
		 * PLACE. It wrapped the host's pthread_mutex_lock, which is the
		 * crossing this case is about, and the process still aborted at exactly
		 * the same point: run 32955888055 printed the hazard and then died on
		 * the free. The lock was never the write that corrupted anything.
		 *
		 * ⭐ Reported the way every other size divergence in this file is
		 * reported. This file's own header says T1.7 writes divergent structs
		 * behind a guard band "because an overrun that only happens on success
		 * is the most misleading result available". T1.6 had the same overrun
		 * and no band.
		 *
		 * ⚠ It does not go through ok(). A hazard is not a failed check: it is
		 * a thing no loader can fix, which is what E50 counts and what section
		 * 11 of docs/REPORT.md is a list of. */
		if (gv.sz_pthread_mutex_t != hv.sz_pthread_mutex_t) {
			printf("    %-4s %-36s host=%llu guest=%llu\n", "DIFF",
			       "a mutex the guest allocates and inits",
			       (unsigned long long)hv.sz_pthread_mutex_t,
			       (unsigned long long)gv.sz_pthread_mutex_t);
			printf("         LIVE HAZARD: pthread_mutex_t is %llu bytes here and %llu\n"
			       "         there. The guest allocates its own size and calls\n"
			       "         pthread_mutex_init, which resolves to OURS and writes this\n"
			       "         size into it. NOT PERFORMED: on this pair it is an\n"
			       "         out-of-bounds write inside the guest, and the allocator\n"
			       "         aborts the process on the next free.\n",
			       (unsigned long long)hv.sz_pthread_mutex_t,
			       (unsigned long long)gv.sz_pthread_mutex_t);
		} else {
			void *gm = g_newmtx();
			ok(gm != NULL, "guest allocated a mutex with its own sizeof", NULL);
			if (gm) {
				r = pthread_mutex_lock((pthread_mutex_t *)gm);
				snprintf(detail, sizeof detail, "returned %d", r);
				ok(r == 0, "host locked the guest's mutex", detail);
				if (r == 0) pthread_mutex_unlock((pthread_mutex_t *)gm);
				free(gm);
			}
		}

		static struct waitctx w;
		pthread_mutex_init(&w.m, NULL);
		pthread_cond_init(&w.c, NULL);
		w.entered = 0;
		w.fired = 0;
		w.rc = -1;
		pthread_t t;
		if (pthread_create(&t, NULL, waiter, &w) != 0) {
			ok(0, "started a waiter thread", strerror(errno));
		} else {
			struct timespec nap = { 0, 10 * 1000 * 1000 };
			int seen = 0;
			for (int i = 0; i < 200 && !seen; i++) {
				pthread_mutex_lock(&w.m);
				seen = w.entered;
				if (seen) w.fired = 1;
				pthread_mutex_unlock(&w.m);
				if (!seen) nanosleep(&nap, NULL);
			}
			int sr = seen ? g_signal(&w.c, &w.m) : -1;
			pthread_join(t, NULL);
			snprintf(detail, sizeof detail,
			         "guest signal returned %d, host wait returned %d%s", sr, w.rc,
			         seen ? "" : " (the waiter never reached the wait)");
			ok(seen && sr == 0 && w.rc == 0, "guest signalled a host condvar", detail);
		}
	}

	printf("\n  T1.7b -- the divergent structs, written by the guest into host storage\n");
	{
		char detail[192];
		/* regmatch_t is the sharpest: glibc's regoff_t is int, musl's is long,
		 * so a musl guest writes 16 bytes per match into an array this side
		 * sized at 8. The guard band turns that from a corrupted neighbour
		 * into a reported failure. */
		struct { regmatch_t m[4]; unsigned char guard[64]; } rm;
		memset(&rm, 0, sizeof rm);
		memset(rm.guard, 0xC3, sizeof rm.guard);
		int r = g_regexec(rm.m, 4, "([a-z]+)-([0-9]+)", "abc-123");
		snprintf(detail, sizeof detail, "regexec=%d match0=[%ld,%ld] guest %llu B/match, host %llu",
		         r, (long)rm.m[0].rm_so, (long)rm.m[0].rm_eo,
		         (unsigned long long)gv.sz_regmatch_t,
		         (unsigned long long)hv.sz_regmatch_t);
		ok(guard_intact(rm.guard, sizeof rm.guard),
		   "regexec into host regmatch_t[4] in bounds", detail);
		if (gv.sz_regmatch_t == hv.sz_regmatch_t)
			ok(r == 0 && rm.m[0].rm_so == 0 && rm.m[0].rm_eo == 7,
			   "and the match offsets are right", detail);
		else
			printf("    %-4s %-36s %s\n", "note", "match offsets not checked",
			       "regmatch_t sizes diverge: the array was written in the guest's layout");

		struct { struct rusage ru; unsigned char guard[64]; } rz;
		memset(&rz, 0, sizeof rz);
		memset(rz.guard, 0xC3, sizeof rz.guard);
		r = g_rusage(&rz.ru);
		snprintf(detail, sizeof detail, "getrusage=%d, guest struct %llu B, host allocated %llu",
		         r, (unsigned long long)gv.sz_rusage, (unsigned long long)hv.sz_rusage);
		ok(guard_intact(rz.guard, sizeof rz.guard),
		   "getrusage into host struct rusage in bounds", detail);

		struct { struct sched_param sp; unsigned char guard[64]; } sz;
		memset(&sz, 0, sizeof sz);
		memset(sz.guard, 0xC3, sizeof sz.guard);
		r = g_schedp(&sz.sp);
		snprintf(detail, sizeof detail, "sched_getparam=%d, guest struct %llu B, host allocated %llu",
		         r, (unsigned long long)gv.sz_sched_param,
		         (unsigned long long)hv.sz_sched_param);
		ok(guard_intact(sz.guard, sizeof sz.guard),
		   "sched_getparam into host sched_param in bounds", detail);

		struct { struct stat st; unsigned char guard[64]; } stz;
		memset(&stz, 0, sizeof stz);
		memset(stz.guard, 0xC3, sizeof stz.guard);
		r = g_stat("/", &stz.st);
		snprintf(detail, sizeof detail, "stat=%d mode=0%o", r, (unsigned)stz.st.st_mode);
		ok(guard_intact(stz.guard, sizeof stz.guard),
		   "stat into host struct stat in bounds", detail);
		ok(r == 0 && (stz.st.st_mode & 0170000) == 0040000,
		   "and / comes back a directory", detail);
	}

	/* Everything above hands the guest storage the HOST allocated, so glibc's
	 * implementation writes glibc's layout into glibc-sized memory and no guard
	 * band can be touched. That is not where the hazard lives. It lives one
	 * step further on: the guest allocates with ITS headers, glibc fills it,
	 * and the guest reads it back at ITS offsets. Nothing crashes and the
	 * numbers are wrong, which is worse.
	 *
	 * These three are reported as findings, not as failures. A divergence here
	 * is a true statement about musl-built code in a glibc process, not a
	 * defect in the loader -- no loader shim can change what offset a compiled
	 * object reads a field at. What they buy is the difference between "six
	 * hazards, all unverified" and a list of which ones are real. */
	printf("\n  T1.7c -- the guest reading back a struct glibc filled\n");
	{
		int64_t (*g_own_re)(const char *, const char *) = NULL;
		int64_t (*g_own_ru)(void) = NULL;
		int (*g_own_ftw)(const char *) = NULL;
		*(void **)(&g_own_re)  = dlsym(h, "abi_own_regexec_end");
		*(void **)(&g_own_ru)  = dlsym(h, "abi_own_rusage_maxrss");
		*(void **)(&g_own_ftw) = dlsym(h, "abi_nftw_count_dirs");
		/* abi_version() already agreed, so all three must be there. Say so if
		 * one is not, rather than printing fewer lines and letting a caller
		 * count zero hazards and believe it. */
		if (!g_own_re || !g_own_ru || !g_own_ftw)
			printf("    NOTE the guest is missing a T1.7c entry point, so the "
			       "hazard count below is incomplete\n");

		if (g_own_re) {
			regmatch_t m[8];
			regex_t re;
			int64_t mine = -1;
			memset(m, 0, sizeof m);
			if (regcomp(&re, "([a-z]+)-([0-9]+)", REG_EXTENDED) == 0) {
				if (regexec(&re, "abc-123", 8, m, 0) == 0) mine = (int64_t)m[0].rm_eo;
				regfree(&re);
			}
			int64_t theirs = g_own_re("([a-z]+)-([0-9]+)", "abc-123");
			printf("    %-4s %-36s host=%lld guest=%lld\n",
			       theirs == mine ? "same" : "DIFF",
			       "regexec, read back at own stride", (long long)mine,
			       (long long)theirs);
			if (theirs != mine)
				printf("         LIVE HAZARD: regoff_t is %llu bytes here and %llu "
				       "there, so the guest\n         reads the wrong words out of "
				       "an array glibc wrote.\n",
				       (unsigned long long)hv.sz_regoff_t,
				       (unsigned long long)gv.sz_regoff_t);
		}

		if (g_own_ru) {
			struct rusage ru;
			memset(&ru, 0, sizeof ru);
			int64_t mine = getrusage(RUSAGE_SELF, &ru) == 0 ? (int64_t)ru.ru_maxrss : -1;
			int64_t theirs = g_own_ru();
			/* Not an equality test: ru_maxrss is a live number that can move
			 * between two calls. What matters is that the guest read a
			 * plausible value from the same offset, not an adjacent field. */
			int plausible = theirs > 0 && mine > 0
			                && theirs >= mine / 2 && theirs <= mine * 2;
			printf("    %-4s %-36s host=%lld guest=%lld\n",
			       plausible ? "same" : "DIFF",
			       "getrusage, read back at own offset",
			       (long long)mine, (long long)theirs);
			if (!plausible)
				printf("         LIVE HAZARD: ru_maxrss sits at %llu here and %llu "
				       "there.\n",
				       (unsigned long long)hv.off_rusage_maxrss,
				       (unsigned long long)gv.off_rusage_maxrss);
		}

		if (g_own_ftw) {
			/* A tree of a known shape: one root, one subdirectory, one file. */
			const char *root = "/tmp/.abi-ftw-tree";
			char sub[128], f[128];
			snprintf(sub, sizeof sub, "%s/sub", root);
			snprintf(f, sizeof f, "%s/file", root);
			mkdir(root, 0700);
			mkdir(sub, 0700);
			FILE *tf = fopen(f, "w");
			if (tf) fclose(tf);
			host_ftw_dirs = 0;
			int mine = nftw(root, host_ftw_cb, 8, 0) == 0 ? host_ftw_dirs : -1;
			int theirs = g_own_ftw(root);
			printf("    %-4s %-36s host=%d guest=%d\n",
			       theirs == mine ? "same" : "DIFF",
			       "nftw, dirs counted with own FTW_D", mine, theirs);
			if (theirs != mine)
				printf("         LIVE HAZARD: FTW_D is %lld here and %lld there, so "
				       "the guest\n         misclassifies every entry glibc reports.\n",
				       (long long)hv.v_FTW_D, (long long)gv.v_FTW_D);
			remove(f);
			rmdir(sub);
			rmdir(root);
		}
	}

	printf("\n%s: %d checks, %d failed\n",
	       fails ? "ABI CROSSING FAILED" : "ABI CROSSING PASSED", checks, fails);
	return fails != 0;
}
