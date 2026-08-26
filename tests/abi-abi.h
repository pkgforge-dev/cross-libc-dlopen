/* The only thing the two sides of the cross-libc boundary agree on.
 *
 * Every field is a fixed-width type on purpose: this struct is the instrument
 * in an experiment about struct layout, so its own layout must not be one of
 * the variables. ABI_VIEW_VERSION guards against a stale guest .so being
 * loaded against a newer host driver, which would misread the table field for
 * field and report differences that are only misalignment.
 *
 * The filler lives here, as one inline function compiled into both sides from
 * identical source. That is what makes the comparison meaningful: the two
 * columns differ only because the HEADERS differ, never because two people
 * wrote two versions of the same table.
 */
#ifndef ABI_ABI_H
#define ABI_ABI_H

#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <glob.h>
#include <pthread.h>
#include <regex.h>
#include <sched.h>
#include <setjmp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <ucontext.h>

#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif

#define ABI_VIEW_VERSION 2u

struct abi_view {
	/* Sizes: the glibc-vs-musl divergences REPORT.md T1.7 lists, plus the
	 * ones any cross-libc call would move through. */
	uint64_t sz_regmatch_t, sz_regex_t, sz_rusage, sz_sched_param;
	uint64_t sz_ucontext_t, sz_jmp_buf, sz_sigset_t, sz_glob_t;
	uint64_t sz_pthread_mutex_t, sz_pthread_cond_t, sz_pthread_attr_t;
	uint64_t sz_time_t, sz_off_t, sz_dirent, sz_stat, sz_FILE_ptr;

	/* OFFSETS, which is the question a size table cannot answer. Two structs
	 * of different total size whose every named field sits at the same offset
	 * cross harmlessly; two structs of the same size whose fields do not, do
	 * not. Only measuring both separates the live hazards from the ones that
	 * merely look alarming in a header diff. */
	uint64_t off_rusage_maxrss, off_rusage_nivcsw, off_stat_mode, off_stat_size;
	uint64_t off_dirent_name, off_sched_priority, sz_regoff_t;

	/* Constants: a number compiled into the guest that this side disagrees
	 * with is a silently wrong answer, not a link error. */
	int64_t v_FTW_D, v_FTW_DNR, v_FTW_DP, v_FTW_F, v_FTW_NS, v_FTW_SL, v_FTW_SLN;
	int64_t v_O_LARGEFILE, v_SIG_BLOCK, v_EWOULDBLOCK, v_RTLD_NEXT;

	/* Addresses: which implementation each side actually reaches. */
	uint64_t addr_malloc, addr_free, addr_errno_location, addr_memcpy;
	uint64_t addr_stdout, addr_pthread_mutex_lock;

	char libc[16];
};

static inline void abi_view_fill(struct abi_view *v) {
	memset(v, 0, sizeof *v);
	v->sz_regmatch_t      = sizeof(regmatch_t);
	v->sz_regex_t         = sizeof(regex_t);
	v->sz_rusage          = sizeof(struct rusage);
	v->sz_sched_param     = sizeof(struct sched_param);
	v->sz_ucontext_t      = sizeof(ucontext_t);
	v->sz_jmp_buf         = sizeof(jmp_buf);
	v->sz_sigset_t        = sizeof(sigset_t);
	v->sz_glob_t          = sizeof(glob_t);
	v->sz_pthread_mutex_t = sizeof(pthread_mutex_t);
	v->sz_pthread_cond_t  = sizeof(pthread_cond_t);
	v->sz_pthread_attr_t  = sizeof(pthread_attr_t);
	v->sz_time_t          = sizeof(time_t);
	v->sz_off_t           = sizeof(off_t);
	v->sz_dirent          = sizeof(struct dirent);
	v->sz_stat            = sizeof(struct stat);
	v->sz_FILE_ptr        = sizeof(FILE *);

	v->off_rusage_maxrss  = offsetof(struct rusage, ru_maxrss);
	v->off_rusage_nivcsw  = offsetof(struct rusage, ru_nivcsw);
	v->off_stat_mode      = offsetof(struct stat, st_mode);
	v->off_stat_size      = offsetof(struct stat, st_size);
	v->off_dirent_name    = offsetof(struct dirent, d_name);
	v->off_sched_priority = offsetof(struct sched_param, sched_priority);
	v->sz_regoff_t        = sizeof(((regmatch_t *)0)->rm_so);

	v->v_FTW_D   = FTW_D;   v->v_FTW_DNR = FTW_DNR; v->v_FTW_DP = FTW_DP;
	v->v_FTW_F   = FTW_F;   v->v_FTW_NS  = FTW_NS;  v->v_FTW_SL = FTW_SL;
	v->v_FTW_SLN = FTW_SLN;
	v->v_O_LARGEFILE = O_LARGEFILE;
	v->v_SIG_BLOCK   = SIG_BLOCK;
	v->v_EWOULDBLOCK = EWOULDBLOCK;
	v->v_RTLD_NEXT   = (int64_t)(intptr_t)RTLD_NEXT;

	/* Taking the address of an imported function yields the address the
	 * loader resolved, so these are the implementations this object really
	 * calls -- with one caveat the host half prints rather than hides: an
	 * EXECUTABLE that takes such an address gets its own PLT entry as the
	 * canonical value, so the two columns can differ for a reason that is
	 * about linking and not about libc. dladdr on each side is what settles
	 * it, and the host does exactly that. */
	v->addr_malloc             = (uint64_t)(uintptr_t)&malloc;
	v->addr_free               = (uint64_t)(uintptr_t)&free;
	v->addr_errno_location     = (uint64_t)(uintptr_t)&__errno_location;
	v->addr_memcpy             = (uint64_t)(uintptr_t)&memcpy;
	v->addr_stdout             = (uint64_t)(uintptr_t)stdout;
	v->addr_pthread_mutex_lock = (uint64_t)(uintptr_t)&pthread_mutex_lock;

#ifdef __GLIBC__
	strcpy(v->libc, "glibc");
#else
	strcpy(v->libc, "musl");
#endif
}

#endif
