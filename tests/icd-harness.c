/* T2.2: cross-libc load a REAL host Vulkan ICD built against musl, from a
 * process carrying the AppImage's own glibc runtime.
 *
 * Isolates the cross-libc load from AppImage mounting, ICD discovery, X11 and
 * rendering: if this is red, nothing downstream is interpretable.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *(*gipa_t)(void *instance, const char *name);

int main(int argc, char **argv) {
    const char *lib = argc > 1 ? argv[1] : "/usr/lib/libvulkan_lvp.so";

    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("FAILED: dlopen: %s\n", dlerror()); return 1; }
    printf("  handle          : %p\n", h);

    /* The ICD entry point every Vulkan loader looks for. */
    gipa_t gipa = (gipa_t)dlsym(h, "vk_icdGetInstanceProcAddr");
    if (!gipa) {
        gipa = (gipa_t)dlsym(h, "vk_icdGetInstanceProcAddrLUNARG");
    }
    if (!gipa) { printf("FAILED: no vk_icdGetInstanceProcAddr: %s\n", dlerror()); return 1; }
    printf("  vk_icdGetInstanceProcAddr: %p\n", (void *)gipa);

    /* Resolve and CALL through it, because a handle alone proves only that ld.so
     * was satisfied, not that the object is usable. */
    void *ci = gipa(NULL, "vkCreateInstance");
    void *ev = gipa(NULL, "vkEnumerateInstanceExtensionProperties");
    printf("  vkCreateInstance          : %p\n", ci);
    printf("  vkEnumerateInstanceExtensionProperties: %p\n", ev);
    if (!ci) { printf("FAILED: vkCreateInstance did not resolve\n"); return 1; }

    /* Where did it actually come from? Guards against silently testing a
     * bundled fallback instead of the host driver. */
    Dl_info info;
    if (dladdr((void *)gipa, &info) && info.dli_fname)
        printf("  provenance      : %s\n", info.dli_fname);

    printf("OK: host ICD loaded and callable\n");
    return 0;
}
