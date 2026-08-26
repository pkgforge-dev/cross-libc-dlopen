/* T4.1 -- exactly one libc family mapped.
 * T4.2 -- every collision-surface soname resolves INSIDE $APPDIR. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int fails;
static const char *COLLIDE[] = { "libstdc++.so.6", "libgcc_s.so.1", "libGL.so.1",
                                 "libxcb.so.1", "libX11.so.6", NULL };

int main(int argc, char **argv) {
    /* Load the host driver closure first, so the check runs against a process
     * that really has host objects in it. */
    if (argc > 1) {
        void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        printf("  driver load: %s\n", h ? "OK" : dlerror());
    }

    const char *appdir = getenv("APPDIR");
    printf("\nT4.2 -- provenance of collision-surface sonames\n");
    for (int i = 0; COLLIDE[i]; i++) {
        void *h = dlopen(COLLIDE[i], RTLD_NOW | RTLD_NOLOAD);
        if (!h) { printf("    %-18s not loaded\n", COLLIDE[i]); continue; }
        /* dladdr on a symbol from it tells us the file actually mapped. */
        void *sym = dlsym(h, "_init");
        Dl_info info;
        const char *where = "(unknown)";
        if (sym && dladdr(sym, &info) && info.dli_fname) where = info.dli_fname;
        else {
            /* no _init: fall back to link_map's l_name */
            struct link_map *lm = NULL;
            if (dlinfo(h, RTLD_DI_LINKMAP, &lm) == 0 && lm && lm->l_name && *lm->l_name)
                where = lm->l_name;
        }
        int bundled = appdir && strncmp(where, appdir, strlen(appdir)) == 0;
        printf("    %-18s %-55s %s\n", COLLIDE[i], where,
               bundled ? "BUNDLED (correct)" : "HOST -- T4.2 VIOLATION");
        if (!bundled) fails++;
    }

    printf("\nT4.1 -- libc families mapped\n");
    FILE *f = fopen("/proc/self/maps", "r");
    int glibc = 0, musl = 0;
    char line[4096];
    while (f && fgets(line, sizeof line, f)) {
        if (strstr(line, "/libc.so.6")) glibc = 1;
        if (strstr(line, "ld-musl") || strstr(line, "libc.musl")) musl = 1;
    }
    if (f) fclose(f);
    printf("    glibc mapped: %s\n", glibc ? "yes" : "no");
    printf("    musl  mapped: %s\n", musl ? "yes" : "no");
    if (glibc && musl) { printf("    T4.1 VIOLATION: two libc families\n"); fails++; }
    else printf("    T4.1 PASS: exactly one libc family\n");

    printf("\n%s (%d failures)\n", fails ? "INVARIANTS FAILED" : "INVARIANTS PASSED", fails);
    return fails != 0;
}
