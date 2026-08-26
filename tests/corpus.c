/* T2.4: cross-libc-dlopen every .so in the host's library directory and count
 * successes. Run once with the feature off and once on: the gate is
 * "successes >= baseline, ZERO regressions". A library that loaded before and
 * does not load after is a regression no aggregate gain excuses. */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/usr/lib";
    DIR *d = opendir(dir);
    if (!d) { fprintf(stderr, "cannot open %s\n", dir); return 2; }

    struct dirent *de;
    int total = 0, ok = 0;
    char path[4096];
    while ((de = readdir(d))) {
        if (!strstr(de->d_name, ".so")) continue;
        /* never poke a libc: cld_never_touch exists for the same reason */
        if (strstr(de->d_name, "libc.musl") || strstr(de->d_name, "ld-musl") ||
            strstr(de->d_name, "libc.so") || strstr(de->d_name, "ld-linux")) continue;
        snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
        total++;
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (h) {
            ok++;
            printf("OK   %s\n", de->d_name);
        } else {
            /* The reason matters: a zero-regression gate you cannot explain is
             * a number, not a result. */
            const char *err = dlerror();
            printf("FAIL %s :: %s\n", de->d_name, err ? err : "(no dlerror)");
        }
    }
    closedir(d);
    fprintf(stderr, "TOTAL=%d OK=%d\n", total, ok);
    return 0;
}
