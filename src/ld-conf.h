/* ld-conf.h: every directory the DISTRO itself calls a library directory.
 *
 * WHY THIS IS A HEADER AND NOT TWO FUNCTIONS. Two things in this repository
 * need the host's own list of library directories, for two different reasons,
 * and until this file existed they would have grown two parsers:
 *
 *   src/runtime-select.c  assembles --library-path for a SWITCHED runtime.
 *                         E44 is what a missing directory costs there: WSL puts
 *                         the GPU vendor userspace in /usr/lib/wsl/lib and makes
 *                         it reachable ONLY by writing /etc/ld.so.conf.d/
 *                         ld.wsl.conf, so under a loader with the cache
 *                         inhibited (E13b) libcuda.so.1 cannot dlopen its own
 *                         libdxcore.so and CUDA reports no device at all.
 *   src/gl-fwd.c          resolves ONE soname, the one it is impersonating,
 *                         which ld.so cannot answer because the shim owns that
 *                         name. It had a hardcoded list of conventional
 *                         directories, and that list was WRONG on Ubuntu's
 *                         alternatives layout, where classic libGL.so.1 lives in
 *                         <triplet>/mesa and classic libEGL.so.1 in
 *                         <triplet>/mesa-egl. Reported from outside,
 *                         by @Samueru-sama.
 *
 * Section 7 says finding libraries is ld.so's job and that ASSEMBLING the path
 * belongs to whatever launches the process. A hardcoded list of somebody else's
 * packaging conventions is neither: it is a GUESS, and the guess drifted. What
 * this file does instead is read the host's own answer out of the plain-text
 * /etc/ld.so.conf, the same benefit the binary cache gives, without touching
 * the binary cache whose parsing is why the cache was inhibited in the first
 * place. It is also the same computation sharun does upstream from the cache
 * (get_ld_cache_dirs, Anylinux-sharun@54208d2); the two are needed
 * independently because sharun assembles the path for the bundled runtime.
 *
 * BOUNDED TWICE OVER. Depth alone is not enough: four levels of thirty-two
 * include globs is a million file opens, and a launcher that can be made to sit
 * in a loop by the contents of /etc is a worse failure than the one it fixes.
 * The budget is the total number of conf files any one walk may read.
 *
 * This is NOT a library search. It yields directories; it opens no library, and
 * both callers still ask for exactly the names they already knew.
 */
#ifndef CROSS_LIBC_DLOPEN_LD_CONF_H
#define CROSS_LIBC_DLOPEN_LD_CONF_H

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#ifndef LDCONF_MAX_PATH
#define LDCONF_MAX_PATH PATH_MAX
#endif
#ifndef LDCONF_DEFAULT_BUDGET
#define LDCONF_DEFAULT_BUDGET 256
#endif
#ifndef LDCONF_MAX_DEPTH
#define LDCONF_MAX_DEPTH 4
#endif

struct ldconf_walk {
	/* Called once per directory named, in file order. Returning non-zero
	 * stops the whole walk, which is what gl-fwd wants, because it is looking for
	 * one file and there is nothing to do after it finds it. */
	int (*dir)(const char *dir, void *ctx);
	/* Never drop anything silently: an incomplete path is the whole failure
	 * this walk exists to prevent. Two fixed strings rather than a varargs
	 * callback, so a caller's logger can be any shape. detail may be NULL. */
	void (*warn)(void *ctx, const char *what, const char *detail);
	void *ctx;
	int budget;
	int budget_warned;
	int stopped;
};

static void ldconf_warn(struct ldconf_walk *w, const char *what,
                        const char *detail) {
	if (w->warn)
		w->warn(w->ctx, what, detail);
}

static int ldconf_walk_file(struct ldconf_walk *w, const char *path, int depth) {
	if (depth > LDCONF_MAX_DEPTH)
		return 0;
	if (w->budget <= 0) {
		if (!w->budget_warned) {
			w->budget_warned = 1;
			ldconf_warn(w, "ld.so.conf walk hit its file budget; "
			               "the rest are ignored", NULL);
		}
		return 0;
	}
	w->budget--;
	FILE *f = fopen(path, "r");
	if (!f)
		return 0;
	char line[LDCONF_MAX_PATH];
	while (fgets(line, sizeof line, f)) {
		char *h = strchr(line, '#');
		if (h)
			*h = '\0';
		char *t = line + strlen(line);
		while (t > line && (t[-1] == '\n' || t[-1] == '\r' || t[-1] == ' ' ||
		                    t[-1] == '\t'))
			*--t = '\0';
		char *v = line;
		while (*v == ' ' || *v == '\t')
			v++;
		if (!*v)
			continue;
		if (!strncmp(v, "include", 7) && (v[7] == ' ' || v[7] == '\t')) {
			char *pat = v + 8;
			while (*pat == ' ' || *pat == '\t')
				pat++;
			if (!*pat)
				continue;
			/* Only the trailing-glob form, a directory, a slash, then a
			 * star and a suffix, occurs in practice. Expand it by hand
			 * rather than pulling in glob(), which would make this depend on
			 * a libc call in the middle of deciding which libc to use. */
			char dir[LDCONF_MAX_PATH], suffix[64];
			char *slash = strrchr(pat, '/');
			if (!slash)
				continue;
			size_t dlen = (size_t)(slash - pat);
			if (dlen >= sizeof dir)
				continue;
			memcpy(dir, pat, dlen);
			dir[dlen] = '\0';
			const char *base = slash + 1;
			const char *star = strchr(base, '*');
			const char *want = star ? star + 1 : base;
			/* A truncated suffix would match the wrong files rather than
			 * none, which is the silent-wrong-answer shape this file exists
			 * to avoid. Skip the include instead and say so. */
			if (strlen(want) >= sizeof suffix) {
				ldconf_warn(w, "include pattern suffix too long, skipped", pat);
				continue;
			}
			snprintf(suffix, sizeof suffix, "%s", want);
			DIR *d = opendir(dir);
			if (!d)
				continue;
			/* readdir order is whatever the filesystem feels like, and the
			 * order of the conf files decides the order of the directories
			 * they name. Collect and sort, so the same machine assembles the
			 * same list twice running: a result that is not reproducible is
			 * not a result. */
			char names[32][128];
			const size_t maxn = sizeof names / sizeof names[0];
			size_t cnt = 0;
			struct dirent *e;
			while ((e = readdir(d))) {
				if (e->d_name[0] == '.')
					continue;
				size_t nl = strlen(e->d_name), sl = strlen(suffix);
				if (sl && (nl < sl || strcmp(e->d_name + nl - sl, suffix)))
					continue;
				if (nl >= sizeof names[0]) {
					ldconf_warn(w, "conf name too long, skipped", e->d_name);
					continue;
				}
				if (cnt == maxn) {
					ldconf_warn(w, "too many conf files in one directory; "
					               "the rest are ignored", dir);
					break;
				}
				size_t j = cnt++;
				while (j > 0 && strcmp(names[j - 1], e->d_name) > 0) {
					memcpy(names[j], names[j - 1], sizeof names[0]);
					j--;
				}
				memcpy(names[j], e->d_name, nl + 1);
			}
			closedir(d);
			for (size_t k = 0; k < cnt && !w->stopped; k++) {
				char sub[LDCONF_MAX_PATH];
				if (snprintf(sub, sizeof sub, "%s/%s", dir, names[k]) >=
				    (int)sizeof sub)
					continue;
				ldconf_walk_file(w, sub, depth + 1);
			}
		} else if (*v == '/') {
			if (w->dir && w->dir(v, w->ctx)) {
				w->stopped = 1;
				break;
			}
		}
		if (w->stopped)
			break;
	}
	fclose(f);
	return w->stopped;
}

/* The entry point. Returns non-zero if the dir callback stopped the walk. */
static int ldconf_each_dir(const char *path,
                           int (*dir)(const char *, void *),
                           void (*warn)(void *, const char *, const char *),
                           void *ctx) {
	struct ldconf_walk w;
	memset(&w, 0, sizeof w);
	w.dir = dir;
	w.warn = warn;
	w.ctx = ctx;
	w.budget = LDCONF_DEFAULT_BUDGET;
	return ldconf_walk_file(&w, path, 0);
}

#endif /* CROSS_LIBC_DLOPEN_LD_CONF_H */
