/* cld-env.h: the project's environment interface.
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
 * THE OPT-IN MARKERS ARE GONE TOO, and for the same reason turned around.
 * cross_libc_dlopen_mode() is now ON BY DEFAULT: preloading this object is
 * already the deliberate act, and requiring a marker file on top of it bought
 * nothing while costing a whole class of silent failure. A consumer that
 * preloaded the object and forgot the marker got a run that did nothing and
 * said nothing about why. CROSS_LIBC_DLOPEN=0 is the off switch.
 *
 * ⛔ WHAT DID NOT GO, AND MUST NOT:
 *
 *   1. APPDIR, below. ⛔ It is NOT a deprecated alias, it is a convention this
 *      project does not own, and the long comment beside it says why removing
 *      it would cost more than it saves.
 *
 *   2. $APPDIR/lib/foreign-dlopen.so, the SLOT that .preload names. That is a
 *      different thing from the .foreign-dlopen-enabled MARKER, which is gone:
 *      the slot is where upstream's shim is replaced, and E30, E37a and E43a
 *      drive upstream's own binary through it.
 *
 *   3. The A/B controls in experiments/40-appimage.sh drive UPSTREAM's binary,
 *      which understands only the old ANYLINUX_* names, so the harness still
 *      sets them for that binary's benefit. No aliasing here ever helped
 *      those, and removing the aliases does not touch them.
 *      scripts/verify-upstream-controls.sh measures the difference: 85 upstream
 *      debug lines with both spellings set, 0 with only the new ones.
 *
 * E84, E85 and E86 in experiments/30-run-tests.sh are what keep this honest:
 * the debug control works, its old spelling is silent, and the old spelling of
 * the enable control cannot turn the feature off.
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

/* The root the bundled libraries live under.
 *
 * CROSS_LIBC_DLOPEN_ROOT is this project's spelling and the one the documents
 * show. ⛔ APPDIR is NOT a deprecated alias of it, and the distinction is the
 * whole reason this comment is long. It is a convention this project does not
 * own: the AppImage runtime exports it into every process it starts, before
 * anything here runs. Dropping it would not remove a spelling, it would
 * require every AppImage consumer to add a wrapper that sets a second variable
 * to a value the first one already holds.
 *
 * It is the same class as the foreign-dlopen.so slot name: somebody else's,
 * kept because it is somebody else's. CROSS_LIBC_DLOPEN_ROOT wins when both
 * are set.
 *
 * ⚠ Measured before this was decided: APPDIR is read at 51 sites across the
 * suites, and nothing sets CROSS_LIBC_DLOPEN_ROOT except one diagnostic echo.
 *
 * ⭐ A CONSUMER WHO WANTS ONE SPELLING CAN HAVE IT, AT BUILD TIME.
 *
 *     make CFLAGS='-O2 -DCLD_STRICT_ENV'
 *
 * builds objects that read CROSS_LIBC_DLOPEN_ROOT and nothing else, which is
 * exactly what was asked for. It is a build-time choice rather than the
 * default because the cost falls on a different person: whoever assembles the
 * bundle knows whether an AppImage runtime is going to export APPDIR into the
 * process, and a library cannot know that. E87 and E88 measure both arms. */
#define CLD_ENV_ROOT     "CROSS_LIBC_DLOPEN_ROOT"
#ifdef CLD_STRICT_ENV
#  define CLD_ENV_ROOT_APPIMAGE NULL
#else
#  define CLD_ENV_ROOT_APPIMAGE "APPDIR"
#endif

/* The directory under the root that holds the bundled libraries. "lib" is
 * what every consumer measured so far uses; it is a default, not a law. */
#define CLD_ENV_LIBDIR   "CROSS_LIBC_DLOPEN_LIBDIR"
#define CLD_DEFAULT_LIBDIR "lib"

static inline const char *cld_root(void)
{
	return cld_getenv(CLD_ENV_ROOT, CLD_ENV_ROOT_APPIMAGE);
}

static inline const char *cld_libdir(void)
{
	const char *v = getenv(CLD_ENV_LIBDIR);
	return (v && *v) ? v : CLD_DEFAULT_LIBDIR;
}

#endif /* CROSS_LIBC_DLOPEN_ENV_H */
