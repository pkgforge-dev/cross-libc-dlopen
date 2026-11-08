/* What musl's build provides and a glibc build does not.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * The vendored sources are musl's own and use two of its internal macros:
 * `hidden` marks a cross-file entry point that is not exported, and
 * `weak_alias` gives a symbol a second name. Neither exists outside musl, and
 * both are definitions rather than behaviour, so supplying them here keeps
 * the vendored text byte-identical to upstream apart from the two include
 * lines that name this directory's headers.
 *
 * The prototypes are the cross-file entry points the sources call. musl
 * assembles them from its own build; a single compiler invocation needs them
 * declared, and C99 makes an implicit declaration a constraint violation.
 */
#ifndef CLD_MUSL_CRYPT_COMPAT_H
#define CLD_MUSL_CRYPT_COMPAT_H

struct crypt_data;

#ifndef hidden
#define hidden
#endif

#ifndef weak_alias
#define weak_alias(old, new) \
	extern __typeof(old) new __attribute__((__weak__, __alias__(#old)))
#endif

char *__crypt_r(const char *, const char *, struct crypt_data *);
char *__crypt_des(const char *, const char *, char *);
char *__crypt_md5(const char *, const char *, char *);
char *__crypt_sha256(const char *, const char *, char *);
char *__crypt_sha512(const char *, const char *, char *);
char *__crypt_blowfish(const char *, const char *, char *);

#endif
