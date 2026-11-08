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
 * crypt_r's struct is why the fallback cannot simply forward. musl's struct
 * crypt_data is 260 bytes and glibc's is 32768, and the caller's size cannot
 * be recovered here. Handing a musl caller's buffer to libxcrypt writes past
 * its end (measured: SIGSEGV). So the real implementation always gets scratch
 * of our own and only the result string is copied back; both ABIs put the
 * output at offset 0.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <string.h>

char *musl_crypt(const char *, const char *);
char *musl_crypt_r(const char *, const char *, void *);
void musl_encrypt(char *, int);
void musl_setkey(const char *);

/* The smaller of the two caller buffers. Every algorithm either library
   implements returns well under this, and a longer result is refused rather
   than written past the end of a musl caller's struct. */
#define CLD_CRYPT_RESULT_MAX 256

char *crypt(const char *key, const char *salt)
{
	static char *(*real)(const char *, const char *);
	if (!real)
		real = (char *(*)(const char *, const char *))dlsym(RTLD_NEXT, "crypt");
	return real ? real(key, salt) : musl_crypt(key, salt);
}

char *crypt_r(const char *key, const char *salt, void *data)
{
	static char *(*real)(const char *, const char *, void *);
	if (!real)
		real = (char *(*)(const char *, const char *, void *))dlsym(RTLD_NEXT, "crypt_r");
	if (!real)
		return musl_crypt_r(key, salt, data);

	char scratch[32768];
	memset(scratch, 0, sizeof scratch);
	char *out = real(key, salt, scratch);
	if (!out)
		return NULL;
	size_t n = strlen(out) + 1;
	if (n > CLD_CRYPT_RESULT_MAX)
		return NULL;
	memcpy(data, out, n);
	return (char *)data;
}

void encrypt(char *block, int edflag)
{
	static void (*real)(char *, int);
	if (!real)
		real = (void (*)(char *, int))dlsym(RTLD_NEXT, "encrypt");
	if (real)
		real(block, edflag);
	else
		musl_encrypt(block, edflag);
}

void setkey(const char *key)
{
	static void (*real)(const char *);
	if (!real)
		real = (void (*)(const char *))dlsym(RTLD_NEXT, "setkey");
	if (real)
		real(key);
	else
		musl_setkey(key);
}
