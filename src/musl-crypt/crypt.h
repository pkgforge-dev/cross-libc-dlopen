/* musl's <crypt.h>, vendored with the sources beside it.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The vendored sources include <crypt.h>, and the floor image has no
 * libcrypt development package, so the header is not there to include. This
 * is musl's own, which is what those sources were written against: the
 * struct below is musl's 260-byte one, not glibc's 32768-byte one. The two
 * are not interchangeable, and src/crypt-shim.c translates at the call.
 *
 * Provenance: musl v1.2.5, include/crypt.h.
 */
#ifndef CLD_MUSL_CRYPT_H
#define CLD_MUSL_CRYPT_H

#ifdef __cplusplus
extern "C" {
#endif

struct crypt_data {
	int initialized;
	char __buf[256];
};

char *crypt(const char *, const char *);
char *crypt_r(const char *, const char *, struct crypt_data *);

#ifdef __cplusplus
}
#endif

#endif
