/* The one thing version-compat.c needs from cross-libc-dlopen.c.
 *
 * They are separate translation units linked into the same cross-libc-dlopen.so.
 * ELF parsing lives in cross-libc-dlopen.c and stays there, because a second ELF reader
 * would drift from the first, and the second one would be the buggy one.
 */
#ifndef CLD_SYMVER_H
#define CLD_SYMVER_H

#include <stddef.h>

/* Name of the DEFAULT version of `sym` in whichever loaded object defines it,
 * written into `out`. Returns 1 on success, 0 when it cannot be determined,
 * including the ordinary case of a symbol that carries no version at all.
 *
 * Read straight out of the defining file's .gnu.version / .gnu.version_d: the
 * default definition is the one whose version index does NOT have the hidden
 * bit set. That is the definition an unversioned reference ought to reach, and
 * asking the ELF is the only way to learn it that does not depend on which
 * glibc's dlsym() semantics you happen to be running on. See E27, where
 * dlsym(RTLD_NEXT, ...) answers with the OBSOLETE definition on glibc 2.31 and
 * the default one on 2.41.
 *
 * Callers hand the answer to dlvsym(), rather than computing an address here,
 * so the loader resolves it and IFUNCs keep working.
 */
__attribute__((visibility("hidden")))
int cld_default_version_of(const char *sym, char *out, size_t outsz);

#endif /* CLD_SYMVER_H */
