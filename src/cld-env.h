/* cld-env.h -- the project's environment interface, and its deprecated aliases.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * This project used to be a component of one consumer and was named after it.
 * Every control was spelled ANYLINUX_*; they are spelled CROSS_LIBC_DLOPEN_*
 * now. The old spellings are still READ, and deleting that would break two
 * things at once:
 *
 *   1. An AppImage built before the rename sets ANYLINUX_LIB_FOREIGN_DLOPEN
 *      from its own launcher and ships a .foreign-dlopen-enabled marker that
 *      quick-sharun wrote. Dropping either name makes this object load and do
 *      nothing in every one of those bundles -- silently, because "the feature
 *      was off" and "the feature was never asked for" produce the same run.
 *
 *   2. The A/B controls in experiments/40-appimage.sh (E30, E37a, E43a) drive
 *      UPSTREAM's binary, which only understands the old names. No aliasing
 *      here can help those -- the harness sets the old names for them too --
 *      but the same reasoning is what this file records.
 *
 * ORDER: the new name wins when both are set. Set-but-empty counts as unset,
 * which is what every caller here already assumed of getenv.
 *
 * ADDING A CONTROL: give it the CROSS_LIBC_DLOPEN_ prefix and call
 * cld_getenv(name, NULL). A new control has no deprecated alias, and passing
 * NULL is how that is said.
 */
#ifndef CROSS_LIBC_DLOPEN_ENV_H
#define CROSS_LIBC_DLOPEN_ENV_H

#include <stdlib.h>

/* The new name, falling back to the deprecated one. `old` may be NULL. */
static inline const char *cld_getenv(const char *neu, const char *old)
{
	const char *v = getenv(neu);
	if (v && *v)
		return v;
	if (old) {
		v = getenv(old);
		if (v && *v)
			return v;
	}
	return NULL;
}

/* The marker filenames, most-current first. A consumer that ships neither is
 * not misconfigured: CROSS_LIBC_DLOPEN=1 on its own is sufficient. */
#define CLD_MARKER_NAMES { ".cross-libc-dlopen-enabled", ".foreign-dlopen-enabled" }

/* The root the bundled libraries live under. APPDIR is one consumer's
 * spelling and stays accepted; CROSS_LIBC_DLOPEN_ROOT is the neutral one. */
#define CLD_ENV_ROOT     "CROSS_LIBC_DLOPEN_ROOT"
#define CLD_ENV_ROOT_ALT "APPDIR"

/* The directory under the root that holds the bundled libraries. "lib" is
 * what every consumer measured so far uses; it is a default, not a law. */
#define CLD_ENV_LIBDIR   "CROSS_LIBC_DLOPEN_LIBDIR"
#define CLD_DEFAULT_LIBDIR "lib"

static inline const char *cld_root(void)
{
	return cld_getenv(CLD_ENV_ROOT, CLD_ENV_ROOT_ALT);
}

static inline const char *cld_libdir(void)
{
	const char *v = getenv(CLD_ENV_LIBDIR);
	return (v && *v) ? v : CLD_DEFAULT_LIBDIR;
}

#endif /* CROSS_LIBC_DLOPEN_ENV_H */
