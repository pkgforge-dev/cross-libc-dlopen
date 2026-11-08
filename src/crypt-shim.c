/* crypt-shim.c: crypt(3) for musl-built host objects.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * musl keeps crypt, crypt_r, encrypt and setkey inside libc.so, so a
 * musl-built host object imports them with no DT_NEEDED on anything. When
 * cross-libc-dlopen drops that libc edge (E6/E7), the names have no provider
 * and the rewritten object fails to load with "undefined symbol: crypt".
 * glibc keeps them in libcrypt.so.1, which is a separate package: a musl host
 * does not ship it and a bundle need not carry it, so loading it is not an
 * answer on the hosts this path exists for.
 *
 * The implementations are musl's own, vendored under musl-crypt/. They cover
 * $1$, $5$, $6$, $2b$ and DES, and agree with libxcrypt byte for byte on all
 * of them. They do NOT cover yescrypt ($y$) or scrypt ($7$), and musl treats
 * an unrecognised salt as DES rather than failing, so a real libcrypt is
 * always preferred when the process has one. That is what the forwarding
 * below is for: an application that links libcrypt.so.1 keeps libxcrypt's
 * answers, and only a process with no libcrypt at all falls back to musl's.
 *
 * crypt_r's struct is why the fallback cannot forward the caller's buffer.
 * THREE sizes are in the wild and none is knowable from here:
 *
 *   musl           260      int initialized; char __buf[256]
 *   libxcrypt    32768      XCRYPT_* nodes, the modern replacement
 *   glibc        131232      keysched + four 32768-byte DES tables
 *
 * The caller's size cannot be recovered, and handing a smaller buffer to a
 * larger implementation writes past its end (measured: SIGSEGV). So the real
 * implementation never sees the caller's buffer: it gets scratch of our own
 * and only the result string is copied back.
 *
 * The copy uses the pointer the implementation returns, not an assumed
 * offset. The three do NOT agree on where that is: musl and libxcrypt return
 * the start of the buffer, and glibc's DES path returns its crypt_3_buf at
 * offset 131200 (measured on glibc 2.24). Reading from the returned pointer
 * covers all three; assuming offset 0 would read the keyschedule instead.
 *
 * The scratch must fit the largest of the three. A buffer sized for
 * libxcrypt is not enough: glibc's own libcrypt.so.1 populates all four DES
 * tables, which is 128 KiB of writes into a 32 KiB buffer (measured on
 * glibc 2.24, SIGSEGV). It is heap-allocated and thread-local rather than a
 * stack array, because a 128 KiB stack frame would put crypt_r out of reach
 * of any thread with a small stack, including the fallback path that never
 * touches it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

char *crypt(const char *, const char *);
char *crypt_r(const char *, const char *, void *);
void encrypt(char *, int);
void setkey(const char *);

char *musl_crypt(const char *, const char *);
char *musl_crypt_r(const char *, const char *, void *);
void musl_encrypt(char *, int);
void musl_setkey(const char *);

/* glibc's struct crypt_data is the largest of the three and this covers it
   with room to spare; see the header. */
#define CLD_CRYPT_SCRATCH 135168

/* The smallest caller buffer any of the three has, less the four bytes of
   musl's leading int. A longer result is refused rather than written past
   the end of a musl caller's struct. */
#define CLD_CRYPT_RESULT_MAX 256

/* The four forwarders below, so a lookup that resolves to US is not mistaken
   for the real implementation. This is the whole hazard of RTLD_DEFAULT: it
   searches the scope the preload is already in, so dlsym("crypt_r") answers
   with this file's own crypt_r and the forwarding recurses until the stack
   ends. Measured: SIGSEGV on the first call. The musl_ names are hidden (the
   build passes -fvisibility=hidden) and so cannot be looked up at all, which
   is why the comparison is against these addresses rather than by name. */
static int is_ours(void *p)
{
	return p == (void *)crypt || p == (void *)crypt_r ||
	       p == (void *)encrypt || p == (void *)setkey;
}

/* Resolve the real implementation, starting the search AFTER this object.
   RTLD_DEFAULT was tried and does not work: it searches from the front of the
   global scope, this preload is in it, so it returns our own crypt_r, is_ours
   rejects it, and the caller silently gets musl instead of the libcrypt the
   application already links. Measured as E109 falling back to a DES hash for
   a $y$ salt. RTLD_NEXT cannot return us, because the search begins at the
   next object, which is exactly what "forward" means.
 *
   ⚠ A libcrypt a plugin brought in with RTLD_LOCAL is not reachable this way
   or any other from here: it is not in the global scope, so neither RTLD_NEXT
   nor RTLD_DEFAULT can see it. That case falls back to musl and gets the DES
   answer for a salt musl does not know. Recorded in docs/todo/measurement.md
   T-07 rather than fixed, because fixing it needs the plugin's own handle.
   Only a real symbol is ever stored, never a null, so a libcrypt loaded after
   the first call is still found. */
static void *real_sym(const char *name)
{
	void *p = dlsym(RTLD_NEXT, name);
	if (!p || is_ours(p))
		return NULL;
	return p;
}

char *crypt(const char *key, const char *salt)
{
	static char *(*real)(const char *, const char *);
	if (!real)
		real = (char *(*)(const char *, const char *))real_sym("crypt");
	return real ? real(key, salt) : musl_crypt(key, salt);
}

char *crypt_r(const char *key, const char *salt, void *data)
{
	static char *(*real)(const char *, const char *, void *);
	static __thread char *scratch;

	if (!real)
		real = (char *(*)(const char *, const char *, void *))real_sym("crypt_r");
	if (!real)
		return musl_crypt_r(key, salt, data);

	if (!scratch) {
		scratch = calloc(1, CLD_CRYPT_SCRATCH);
		if (!scratch)
			return NULL;
	}

	char *out = real(key, salt, scratch);
	if (!out) {
		/* libxcrypt leaves "*0" in the caller's output on failure and
		   this path has not touched it; the sentinel is what a caller
		   checking the buffer expects. */
		if (data)
			((char *)data)[0] = '\0';
		return NULL;
	}
	size_t n = strlen(out) + 1;
	if (n > CLD_CRYPT_RESULT_MAX) {
		if (data)
			((char *)data)[0] = '\0';
		return NULL;
	}
	memcpy(data, out, n);
	return (char *)data;
}

void encrypt(char *block, int edflag)
{
	static void (*real)(char *, int);
	if (!real)
		real = (void (*)(char *, int))real_sym("encrypt");
	if (real)
		real(block, edflag);
	else
		musl_encrypt(block, edflag);
}

void setkey(const char *key)
{
	static void (*real)(const char *);
	if (!real)
		real = (void (*)(const char *))real_sym("setkey");
	if (real)
		real(key);
	else
		musl_setkey(key);
}
