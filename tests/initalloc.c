/* An LD_PRELOAD allocator that calls forwarded symbols while it is still
 * initialising, as FEX's jemalloc does with sched_getaffinity().
 *
 * A real allocator holds its init lock there, so an allocation made from
 * inside the call blocks on that lock for good. This one reports the re-entry
 * and exits 3 instead of deadlocking, so the failure is a status rather than a
 * hang. Exit 0 means the first call to each symbol did not allocate.
 *
 * A clean run says "init ran" once. An exit 0 without it is what an allocator
 * that ld.so never loaded produces, so the harness counts the line.
 *
 * It hooks malloc, calloc and realloc. glibc's calloc does not reach malloc,
 * so hooking malloc alone passes an interposer that callocs.
 *
 * The three symbols are forwarded from src/version-compat.c, each resolved on
 * its own first call, so each one walks the whole resolution path.
 *
 * glibc 2.33 and older allocate in dlsym() itself: a thread's first dl* call
 * callocs its error buffer. That allocation belongs to the loader and no
 * change to the preload removes it, so by default this takes it before the
 * clock starts and measures what the preload owns. Built with
 * -DINITALLOC_COLD it does not, which measures the loader's share too.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stddef.h>
#include <unistd.h>

#define VIS __attribute__((visibility("default")))

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);

static volatile int in_init;
static volatile int priming;
static int initialised;

static void reentered(const char *what) {
	static const char msg[] = "initalloc: allocator re-entered during its own init via ";
	(void)!write(2, msg, sizeof(msg) - 1);
	(void)!write(2, what, (size_t)(__builtin_strlen(what)));
	(void)!write(2, "\n", 1);
	_exit(3);
}

static void init_once(const char *what) {
	if (in_init)
		reentered(what);
	if (initialised || priming)
		return;
#ifndef INITALLOC_COLD
	priming = 1;
	(void)dlsym(RTLD_DEFAULT, "malloc");
	priming = 0;
#endif
	in_init = 1;
	cpu_set_t set;
	CPU_ZERO(&set);
	sched_getaffinity(0, sizeof(set), &set);
	pthread_cond_t cond;
	pthread_cond_init(&cond, NULL);
	pthread_cond_destroy(&cond);
	in_init = 0;
	initialised = 1;
	static const char ran[] = "initalloc: init ran\n";
	(void)!write(2, ran, sizeof(ran) - 1);
}

VIS void *malloc(size_t n) {
	init_once("malloc");
	return __libc_malloc(n);
}

VIS void *calloc(size_t a, size_t b) {
	init_once("calloc");
	return __libc_calloc(a, b);
}

VIS void *realloc(void *p, size_t n) {
	init_once("realloc");
	return __libc_realloc(p, n);
}
