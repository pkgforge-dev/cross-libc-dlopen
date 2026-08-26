/* Minimal Vulkan probe: bundled loader + host ICD, no window system.
 * vulkaninfo needs no surface, so neither does this. It isolates the
 * cross-libc load from X11 and rendering entirely. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

typedef void *VkInstance;
typedef void *VkPhysicalDevice;
typedef int VkResult;
struct AppInfo { uint32_t sType; const void *pNext; const char *pApplicationName;
                 uint32_t applicationVersion; const char *pEngineName;
                 uint32_t engineVersion; uint32_t apiVersion; };
struct CreateInfo { uint32_t sType; const void *pNext; uint32_t flags;
                    const struct AppInfo *pApplicationInfo;
                    uint32_t enabledLayerCount; const char *const *ppEnabledLayerNames;
                    uint32_t enabledExtensionCount; const char *const *ppEnabledExtensionNames; };
struct Props { uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType;
               char deviceName[256]; uint8_t uuid[16];
               /* VkPhysicalDeviceProperties continues with VkPhysicalDeviceLimits
                * and VkPhysicalDeviceSparseProperties, 824 bytes in total for
                * Vulkan 1.3. Nothing here reads them, but the DRIVER WRITES them,
                * so the space has to exist. Without it the probe smashed its own
                * stack on every SUCCESSFUL enumeration, which reads exactly like a
                * driver crash and is not one. */
               unsigned char tail[2048];
               unsigned char guard[64]; };

int main(void) {
    /* Unbuffered: when something really does crash, the last line printed is
       the whole diagnosis, and a pipe would swallow it. */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *loader = getenv("VKPROBE_LOADER");
    if (!loader) loader = "libvulkan.so.1";

    void *vk = dlopen(loader, RTLD_NOW | RTLD_GLOBAL);
    if (!vk) { printf("FAILED: dlopen %s: %s\n", loader, dlerror()); return 1; }

    VkResult (*create)(const struct CreateInfo *, const void *, VkInstance *) =
        dlsym(vk, "vkCreateInstance");
    VkResult (*enumerate)(VkInstance, uint32_t *, VkPhysicalDevice *) =
        dlsym(vk, "vkEnumeratePhysicalDevices");
    void (*getprops)(VkPhysicalDevice, struct Props *) =
        dlsym(vk, "vkGetPhysicalDeviceProperties");
    if (!create || !enumerate) { printf("FAILED: loader entry points missing\n"); return 1; }

    struct AppInfo ai = { 0 };
    ai.sType = 0;                 /* VK_STRUCTURE_TYPE_APPLICATION_INFO */
    ai.pApplicationName = "vkprobe";
    ai.apiVersion = (1u << 22) | (0u << 12);   /* VK_API_VERSION_1_0 */
    struct CreateInfo ci = { 0 };
    ci.sType = 1;                 /* VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO */
    ci.pApplicationInfo = &ai;

    VkInstance inst = NULL;
    VkResult r = create(&ci, NULL, &inst);
    printf("  vkCreateInstance          : %d %s\n", r, r == 0 ? "(VK_SUCCESS)" : "(FAILED)");
    if (r != 0) return 1;

    uint32_t n = 0;
    r = enumerate(inst, &n, NULL);
    printf("  vkEnumeratePhysicalDevices: %d, count=%u\n", r, n);
    if (r != 0) { printf("FAILED: enumerate returned %d\n", r); return 1; }
    if (n == 0) { printf("FAILED: zero devices\n"); return 1; }

    VkPhysicalDevice devs[8];
    if (n > 8) n = 8;
    r = enumerate(inst, &n, devs);
    if (r != 0) { printf("FAILED: second enumerate returned %d\n", r); return 1; }
    for (uint32_t i = 0; i < n && getprops; i++) {
        struct Props p; memset(&p, 0, sizeof p);
        memset(p.guard, 0x5A, sizeof p.guard);
        getprops(devs[i], &p);
        for (size_t g = 0; g < sizeof p.guard; g++)
            if (p.guard[g] != 0x5A) {
                printf("FAILED: driver wrote past VkPhysicalDeviceProperties\n");
                return 1;
            }
        printf("  device[%u]                 : %s\n", i, p.deviceName);
    }
    printf("OK: %u physical device(s)\n", n);
    return 0;
}
