/* The three properties src/version-compat.c is built on. One per argv selector
 * so the evidence table gets one line each.
 *
 *   e24  An unversioned reference and dlsym do not have to agree, and the
 *        obsolete definition really does reject what Mesa passes it. This is
 *        the trap itself, stated in terms of libc alone.
 *
 *   e25  The memcpy exclusion in version-compat.c is justified rather than
 *        assumed: both definitions agree byte-for-byte over 4096 size and
 *        alignment combinations, so a conforming caller cannot tell them
 *        apart and interposing every memcpy in a rendering process buys
 *        nothing.
 *
 *   e27  WHICH resolution primitive may be trusted to return the default
 *        definition. This is the measurement that decided the implementation:
 *        dlsym(RTLD_NEXT, ...) answers with the OBSOLETE definition on glibc
 *        2.31 and the default one on 2.41, so version-compat.c cannot use it.
 *        It reads the version name out of the defining object's ELF and hands
 *        that to dlvsym instead, which is correct on both.
 *
 * Each prints <SELECTOR> PASSED and exits 0, or FAILED and exits 1.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* x86-64's base version: the ABI the port shipped with in 2002. A historical
 * constant, not something a future glibc renumbers. */
#define OBSOLETE_VER "GLIBC_2.2.5"
/* The version the condition-variable ABI moved to in 2003, likewise fixed. */
#define CURRENT_VER  "GLIBC_2.3.2"

typedef int (*cond_init_t)(pthread_cond_t *, const pthread_condattr_t *);
typedef void *(*memcpy_t)(void *, const void *, size_t);

static int fails;

static void fail(const char *what) {
	printf("  FAIL: %s\n", what);
	fails++;
}

/* Exactly what Mesa's u_cnd_monotonic_init() does. */
static int call_cond_init(cond_init_t fn) {
	pthread_condattr_t attr;
	pthread_cond_t cond;
	if (pthread_condattr_init(&attr) != 0)
		return -1;
	if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0) {
		pthread_condattr_destroy(&attr);
		return -2;
	}
	int r = fn(&cond, &attr);
	if (r == 0)
		pthread_cond_destroy(&cond);
	pthread_condattr_destroy(&attr);
	return r;
}

static int e24(void) {
	cond_init_t current = (cond_init_t)dlvsym(RTLD_DEFAULT, "pthread_cond_init", CURRENT_VER);
	cond_init_t obsolete = (cond_init_t)dlvsym(RTLD_DEFAULT, "pthread_cond_init", OBSOLETE_VER);

	if (!obsolete || !current) {
		/* Then there is no trap on this libc and nothing to prove. Say so
		 * rather than reporting a property that was never tested. */
		printf("  SKIPPED: this libc does not export pthread_cond_init at both "
		       "%s and %s\n", OBSOLETE_VER, CURRENT_VER);
		return 0;
	}
	if (current == obsolete) {
		printf("  SKIPPED: both versions are the same code, no trap here\n");
		return 0;
	}

	int r_current = call_cond_init(current);
	int r_obsolete = call_cond_init(obsolete);
	printf("  pthread_cond_init@%-11s -> %d\n", CURRENT_VER, r_current);
	printf("  pthread_cond_init@%-11s -> %d %s\n", OBSOLETE_VER, r_obsolete,
	       r_obsolete == EINVAL ? "(EINVAL)" : "");

	if (r_current != 0)
		fail("the current definition rejected a monotonic condattr");
	if (r_obsolete != EINVAL)
		fail("the obsolete definition did not return EINVAL; this libc's "
		     "compat symbol is not the one this is about");
	return fails;
}

static int e25(void) {
	memcpy_t def = (memcpy_t)dlsym(RTLD_DEFAULT, "memcpy");
	memcpy_t old = (memcpy_t)dlvsym(RTLD_DEFAULT, "memcpy", OBSOLETE_VER);

	if (!old || !def || old == def) {
		printf("  SKIPPED: this libc has one memcpy, nothing to exclude\n");
		return 0;
	}

	enum { PAD = 32, MAXLEN = 256, ALIGNS = 16 };
	static unsigned char src[MAXLEN + ALIGNS + PAD];
	static unsigned char a[MAXLEN + PAD], b[MAXLEN + PAD];
	unsigned cases = 0;

	for (size_t i = 0; i < sizeof(src); i++)
		src[i] = (unsigned char)(i * 31u + 7u);

	for (unsigned al = 0; al < ALIGNS; al++) {
		for (unsigned len = 0; len < MAXLEN; len++) {
			memset(a, 0xAA, sizeof(a));
			memset(b, 0xAA, sizeof(b));
			def(a, src + al, len);
			old(b, src + al, len);
			if (memcmp(a, b, sizeof(a)) != 0) {
				printf("  differ at align=%u len=%u\n", al, len);
				fail("the two memcpy definitions disagree on a "
				     "non-overlapping copy; the exclusion is unjustified");
				return fails;
			}
			cases++;
		}
	}
	printf("  %u size/alignment combinations, byte-identical\n", cases);
	return fails;
}

static int e27(void) {
	void *obsolete = dlvsym(RTLD_DEFAULT, "pthread_cond_init", OBSOLETE_VER);
	void *current = dlvsym(RTLD_DEFAULT, "pthread_cond_init", CURRENT_VER);
	if (!obsolete || !current || obsolete == current) {
		printf("  SKIPPED: no trap on this libc, no primitive to choose between\n");
		return 0;
	}

	struct { const char *name; void *got; } probe[] = {
		{ "dlsym(RTLD_DEFAULT)",          dlsym(RTLD_DEFAULT, "pthread_cond_init") },
		{ "dlsym(RTLD_NEXT)",             dlsym(RTLD_NEXT, "pthread_cond_init") },
		{ "dlvsym(RTLD_NEXT, current)",   dlvsym(RTLD_NEXT, "pthread_cond_init", CURRENT_VER) },
	};

	int next_agrees = 1;
	for (size_t i = 0; i < sizeof(probe) / sizeof(*probe); i++) {
		const char *verdict = probe[i].got == current ? "default"
		                    : probe[i].got == obsolete ? "OBSOLETE"
		                    : probe[i].got ? "other" : "(null)";
		printf("  %-30s -> %s\n", probe[i].name, verdict);
	}
	if (probe[1].got != current)
		next_agrees = 0;

	/* The one that MUST hold: the primitive version-compat.c actually uses. */
	if (probe[2].got != current)
		fail("dlvsym(RTLD_NEXT, sym, <default version>) did not return the "
		     "default definition; version-compat.c has no working primitive here");

	printf("  dlsym(RTLD_NEXT) %s the default on this glibc%s\n",
	       next_agrees ? "IS" : "is NOT",
	       next_agrees ? "" : " -- which is why the version name is read from the ELF");
	return fails;
}

int main(int argc, char **argv) {
	const char *sel = argc > 1 ? argv[1] : "e24";
	int rc;

	if (!strcmp(sel, "e24"))      rc = e24();
	else if (!strcmp(sel, "e25")) rc = e25();
	else if (!strcmp(sel, "e27")) rc = e27();
	else { printf("usage: vertrap e24|e25|e27\n"); return 2; }

	printf("%s %s\n", sel, rc ? "FAILED" : "PASSED");
	return rc ? 1 : 0;
}
