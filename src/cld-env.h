/* cld-env.h -- the project's environment interface.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Every control is spelled CROSS_LIBC_DLOPEN_*, and there is exactly one
 * spelling of each. This file is where that is enforced and where the two
 * names that are NOT this project's are kept apart from the ones that are.
 *
 * THE DEPRECATED ALIASES ARE GONE, and their removal is a decision rather than
 * an oversight. This project used to be a component of one consumer and was
 * named after it, so every control also answered to an ANYLINUX_* spelling.
 * Nothing consumes those: there has never been a published release, so no
 * bundle exists that sets one. What the aliases cost was real. Every control
 * had two names, only one of which appeared in any document, so a reader could
 * not tell which was authoritative and a check could not tell either.
 *
 * ⛔ WHAT DID NOT GO, AND MUST NOT:
 *
 *   1. APPDIR, below, is not a deprecated alias. It is one consumer's spelling
 *      of the bundle root, it is what the suites set, and CROSS_LIBC_DLOPEN_ROOT
 *      is the neutral name beside it.
 *
 *   2. .foreign-dlopen-enabled, below, is UPSTREAM's marker name. quick-sharun
 *      writes it and .preload names it. Renaming it turns E30, E37a and E43a
 *      into silent passes.
 *
 *   3. The A/B controls in experiments/40-appimage.sh drive UPSTREAM's binary,
 *      which understands only the old ANYLINUX_* names, so the harness still
 *      sets them for that binary's benefit. No aliasing here ever helped
 *      those, and removing the aliases does not touch them.
 *      scripts/verify-upstream-controls.sh measures the difference: 85 upstream
 *      debug lines with both spellings set, 0 with only the new ones.
 *
 * E84 and E85 in experiments/30-run-tests.sh are the pair that keeps this
 * honest: the debug control works, and the old spelling of it is silent.
 *
 * ORDER: the primary name wins when both are set. Set-but-empty counts as
 * unset, which is what every caller here already assumed of getenv.
 *
 * ADDING A CONTROL: give it the CROSS_LIBC_DLOPEN_ prefix and call
 * cld_getenv(name, NULL). NULL is how "this control has one name" is said, and
 * it is the right answer for every new control.
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
