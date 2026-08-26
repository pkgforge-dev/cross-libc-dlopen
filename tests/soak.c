/* T5 -- does it keep working?
 *
 * N dlopen/dlsym/dlclose cycles over a host driver, reporting RSS and open file
 * descriptors so a leak shows up as a trend rather than a feeling.
 *
 * Two things this is deliberately careful about:
 *
 *  - cross-libc-dlopen hands out cached handles and adds RTLD_NODELETE, so a
 *    dlclose here will NOT unmap the object. That is the design (a stray
 *    dlclose from one caller must not yank mappings another still holds), so
 *    the leak this looks for is per-CYCLE growth: a rewritten copy emitted
 *    every time, a handle table that grows, an fd never closed.
 *
 *  - the first cycle is expensive and proves nothing about leaking. The
 *    baseline is taken AFTER it, so the reported delta is steady-state.
 *
 *    tests/soak <library> [cycles]
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long rss_kb(void) {
	FILE *f = fopen("/proc/self/status", "r");
	char line[256];
	long kb = -1;
	while (f && fgets(line, sizeof line, f))
		if (sscanf(line, "VmRSS: %ld kB", &kb) == 1)
			break;
	if (f) fclose(f);
	return kb;
}

static int open_fds(void) {
	DIR *d = opendir("/proc/self/fd");
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d)))
		if (e->d_name[0] != '.')
			n++;
	if (d) closedir(d);
	return n - 1;                 /* the opendir handle itself */
}

/* Rewritten images the loader emitted, so "one per cycle" cannot hide. */
static int tmp_copies(void) {
	const char *dir = getenv("XDG_RUNTIME_DIR");
	if (!dir || !*dir) dir = getenv("TMPDIR");
	if (!dir || !*dir) dir = "/tmp";
	DIR *d = opendir(dir);
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d)))
		/* The hostrt marker runtime-select writes shares this prefix and is
		 * not a rewritten image; excluded so a leak count stays a leak count. */
		if (strstr(e->d_name, "cross-libc-dlopen-") &&
		    !strstr(e->d_name, "cross-libc-dlopen-hostrt-"))
			n++;
	if (d) closedir(d);
	return n;
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);
	if (argc < 2) {
		printf("usage: soak <library> [cycles]\n");
		return 2;
	}
	const char *lib = argv[1];
	int cycles = argc > 2 ? atoi(argv[2]) : 100;
	long base_rss = 0;
	int base_fds = 0, base_tmp = 0, failures = 0;

	for (int i = 0; i < cycles; i++) {
		void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
		if (!h) {
			printf("FAILED: cycle %d: %s\n", i, dlerror());
			return 1;
		}
		/* A handle alone proves ld.so was satisfied. Resolve and call. */
		void *(*gipa)(void *, const char *) =
			(void *(*)(void *, const char *))dlsym(h, "vk_icdGetInstanceProcAddr");
		if (gipa && !gipa(NULL, "vkCreateInstance"))
			failures++;
		dlclose(h);

		if (i == 0) {
			base_rss = rss_kb();
			base_fds = open_fds();
			base_tmp = tmp_copies();
			printf("  after cycle 1  : rss=%ld kB fds=%d rewritten=%d\n",
			       base_rss, base_fds, base_tmp);
		}
	}

	long end_rss = rss_kb();
	int end_fds = open_fds(), end_tmp = tmp_copies();
	printf("  after cycle %-3d: rss=%ld kB fds=%d rewritten=%d\n",
	       cycles, end_rss, end_fds, end_tmp);
	printf("  delta over %d steady-state cycles: rss=%+ld kB fds=%+d rewritten=%+d\n",
	       cycles - 1, end_rss - base_rss, end_fds - base_fds, end_tmp - base_tmp);

	if (failures) {
		printf("FAILED: %d cycle(s) resolved vkCreateInstance to NULL\n", failures);
		return 1;
	}
	/* One rewritten image per source object is correct and is emitted under a
	 * content-derived name, so the count must not grow with cycles at all. */
	if (end_tmp != base_tmp) {
		printf("FAILED: rewritten images grew by %d over %d cycles\n",
		       end_tmp - base_tmp, cycles - 1);
		return 1;
	}
	if (end_fds > base_fds) {
		printf("FAILED: %d file descriptor(s) leaked\n", end_fds - base_fds);
		return 1;
	}
	/* RSS is noisy; a real per-cycle leak of anything driver-sized shows as
	 * megabytes, not kilobytes. 512 kB over 99 cycles is under 6 kB a cycle. */
	if (end_rss - base_rss > 512) {
		printf("FAILED: RSS grew %ld kB over %d cycles\n",
		       end_rss - base_rss, cycles - 1);
		return 1;
	}
	printf("SOAK PASSED: %d cycles, no growth\n", cycles);
	return 0;
}
