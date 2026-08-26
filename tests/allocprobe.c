/* Does the ICD actually run out of memory, or is VK_ERROR_OUT_OF_HOST_MEMORY
 * standing in for something else? Interpose the allocator family and report
 * every NULL return.
 *
 * Every counter has a TOTAL beside it, because "0 NULL allocations" on its own
 * is not evidence: it reads identically to "this probe interposed nothing at
 * all", which is what happens if the preload order is wrong, if the process
 * resolved malloc before this object entered the scope, or if the library
 * under test brings its own allocator. A negative result has to carry the
 * proof that it was in a position to observe a positive one. (Suggested in
 * issue #1, where the same test was run with 27076 interposed calls and the
 * counter was what made the answer usable.)
 *
 * dl_iterate_phdr and dladdr are counted too: Mesa uses them to find its own
 * build-id for the pipeline-cache UUID, which is one of the few things that
 * behaves differently when an object is loaded from a rewritten copy.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>
#include <stddef.h>

#define VIS __attribute__((visibility("default")))

static unsigned long n_malloc, n_calloc, n_realloc, n_memalign, n_aligned;
static unsigned long n_iters, n_dladdr, n_dladdr_fail;
static int nulls;

VIS void *malloc(size_t n) {
    static void *(*real)(size_t);
    if (!real) real = dlsym(RTLD_NEXT, "malloc");
    n_malloc++;
    void *p = real(n);
    if (!p && n) { fprintf(stderr, "  [alloc] malloc(%zu) -> NULL\n", n); nulls++; }
    return p;
}
VIS void *calloc(size_t a, size_t b) {
    static void *(*real)(size_t, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "calloc");
    n_calloc++;
    void *p = real(a, b);
    if (!p && a && b) { fprintf(stderr, "  [alloc] calloc(%zu,%zu) -> NULL\n", a, b); nulls++; }
    return p;
}
VIS void *realloc(void *q, size_t n) {
    static void *(*real)(void *, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "realloc");
    n_realloc++;
    void *p = real(q, n);
    if (!p && n) { fprintf(stderr, "  [alloc] realloc(%zu) -> NULL\n", n); nulls++; }
    return p;
}
VIS int posix_memalign(void **out, size_t al, size_t n) {
    static int (*real)(void **, size_t, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "posix_memalign");
    n_memalign++;
    int r = real(out, al, n);
    if (r) { fprintf(stderr, "  [alloc] posix_memalign(%zu,%zu) -> %d\n", al, n, r); nulls++; }
    return r;
}
VIS void *aligned_alloc(size_t al, size_t n) {
    static void *(*real)(size_t, size_t);
    if (!real) real = dlsym(RTLD_NEXT, "aligned_alloc");
    n_aligned++;
    void *p = real(al, n);
    if (!p) { fprintf(stderr, "  [alloc] aligned_alloc(%zu,%zu) -> NULL\n", al, n); nulls++; }
    return p;
}
VIS int dl_iterate_phdr(int (*cb)(struct dl_phdr_info *, size_t, void *), void *d) {
    static int (*real)(int (*)(struct dl_phdr_info *, size_t, void *), void *);
    if (!real) real = dlsym(RTLD_NEXT, "dl_iterate_phdr");
    n_iters++;
    return real(cb, d);
}
VIS int dladdr(const void *addr, Dl_info *info) {
    static int (*real)(const void *, Dl_info *);
    if (!real) real = dlsym(RTLD_NEXT, "dladdr");
    n_dladdr++;
    int r = real(addr, info);
    if (!r) n_dladdr_fail++;
    return r;
}

__attribute__((destructor)) static void report(void) {
    unsigned long total = n_malloc + n_calloc + n_realloc + n_memalign + n_aligned;
    fprintf(stderr,
            "  [alloc] SUMMARY: %lu allocator calls interposed "
            "(malloc %lu, calloc %lu, realloc %lu, posix_memalign %lu, aligned_alloc %lu)\n"
            "  [alloc]          %d returned NULL\n"
            "  [alloc]          dl_iterate_phdr %lu, dladdr %lu (%lu failed)\n",
            total, n_malloc, n_calloc, n_realloc, n_memalign, n_aligned,
            nulls, n_iters, n_dladdr, n_dladdr_fail);
    if (total == 0)
        fprintf(stderr,
                "  [alloc] NOT INTERPOSED: zero allocator calls reached this probe, so\n"
                "  [alloc]          \"no NULL allocations\" says nothing. Check the preload\n"
                "  [alloc]          order, and that this object is in the GLOBAL scope.\n");
}
