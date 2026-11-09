/* cryptprobe.c: does a musl-shaped object's crypt reference RESOLVE?
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * E111, E112 and E113 in experiments/30-run-tests.sh all score the preload's
 * own debug lines. A debug line says what the code intended; it cannot say
 * whether a symbol resolved, and the difference is the whole feature. A build
 * that opened the bundle's libcrypt RTLD_LOCAL prints the same "loaded from
 * the bundle" line as one that loaded it globally, and only the second makes
 * a musl object's `crypt` resolvable.
 *
 * So this object is the assertion the debug strings cannot be. Built as a
 * shared library with NO DT_NEEDED on a libc crypt provider, importing `crypt`
 * by name, which is what a musl-built host driver looks like once
 * cross-libc-dlopen drops its libc edge: musl keeps crypt inside libc.so, so
 * the object imports it with no edge to follow.
 *
 * The caller loads it with dlopen and calls crypt_probe(). It returns the
 * number of the checks that held, and 0 if any failed:
 *
 *   1  the object loaded at all, which it cannot do unresolved
 *   2  crypt() returned something
 *   4  the implementation that answered is outside this object
 *   8  the answer is the hash libxcrypt gives for this salt
 *
 * ⭐ Check 8 is the one that matters for correctness rather than presence.
 * musl's own DES fallback would answer a $6$ salt with a DES hash of its first
 * eight characters, so a shim that interposed would pass 1, 2 and 4 and fail 8.
 *
 * ⚠ Built with -Wl,--unresolved-symbols=ignore-all, because the point is that
 * `crypt` is UNDEFINED at link time and satisfied at load time. Linking it
 * against a libcrypt would make the object carry the very DT_NEEDED this is
 * meant to do without.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

/* glibc's prototype, declared here rather than included: the floor image has
   no libcrypt development headers, and including <crypt.h> would pull one. */
extern char *crypt(const char *, const char *);

/* The $6$ answer libxcrypt gives for this salt and key. */
static const char want[] =
	"$6$s$uS8ebqSHbt1SxeJHmjJJ8XiNODU1MHXmq8vuR"
	".PTjWjqzI2O0O5Fqib4lhr5K8OJ/hMYgFNUo1BLK3I7X/8yn/";

/* 16: the implementation that answered lives under $CLD_CRYPT_PROBE_ROOT.
 *
 * ⚠ This bit exists because the other four cannot tell "the bundle's copy
 * won" from "the host's copy answered". The bundle loader still searches the
 * host's /etc/ld.so.cache, so a build whose bundle tier did nothing at all
 * resolves crypt from /lib/x86_64-linux-gnu/libcrypt.so.1 and returns 15.
 * Measured: a list naming the wrong soname returned 15 that way. A caller
 * that has set the variable is asking the bundle question and gets 31 only
 * when the answer came from inside the root. */
static int from_root(void)
{
	const char *root = getenv("CLD_CRYPT_PROBE_ROOT");
	if (!root || !*root)
		return 0;
	Dl_info info;
	if (!dladdr((void *)crypt, &info) || !info.dli_fname)
		return 0;
	return strncmp(info.dli_fname, root, strlen(root)) == 0;
}

int crypt_probe(void)
{
	int score = 0;

	score |= 1;			/* reaching here means the load resolved */

	char *got = crypt("password", "$6$s");
	if (!got)
		return score;

	score |= 2;

	/* 4: the implementation that answered is NOT inside this object. dlsym
	   against (void *)crypt was the first shape of this and it never fires:
	   this object's own call site is bound to whatever the lookup chose, so
	   the two are equal by construction. dladdr reports the module the
	   address belongs to, which is the question actually being asked. */
	Dl_info info;
	if (dladdr((void *)crypt, &info) && info.dli_fname) {
		const char *base = strrchr(info.dli_fname, '/');
		base = base ? base + 1 : info.dli_fname;
		if (strcmp(base, "libcryptprobe.so") != 0)
			score |= 4;
	}

	/* 8: and it is the right answer, not musl's DES fallback. */
	if (strcmp(got, want) == 0)
		score |= 8;

	if (from_root())
		score |= 16;

	return score;
}
