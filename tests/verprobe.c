/* E22/E23: the probe object for the version-binding trap.
 *
 * Built as a shared object, then version-stripped by the harness exactly the
 * way cross-libc-dlopen.c strips a host driver, then dlopen'd and called.
 *
 * The return value IS the measurement:
 *      0   the pthread_cond_init reference bound to the default definition
 *     22   it bound to glibc's obsolete pthread_cond_init@GLIBC_2.2.5, whose
 *          whole body is `if (cond_attr != NULL) return EINVAL;`
 *
 * That single number is the difference between Mesa enumerating a GPU and Mesa
 * reporting VK_ERROR_OUT_OF_HOST_MEMORY with zero devices, because Mesa's
 * u_cnd_monotonic_init() does precisely this call with precisely this
 * attribute. No Vulkan, no musl and no AppImage are involved in reproducing it.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <time.h>

__attribute__((visibility("default")))
int probe_cond_init(void) {
	pthread_condattr_t attr;
	pthread_cond_t cond;

	if (pthread_condattr_init(&attr) != 0)
		return -1;
	/* A monotonic clock is the only reason an attribute is passed at all,
	 * and passing an attribute is what the obsolete definition rejects. */
	if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0) {
		pthread_condattr_destroy(&attr);
		return -2;
	}

	int r = pthread_cond_init(&cond, &attr);
	if (r == 0)
		pthread_cond_destroy(&cond);
	pthread_condattr_destroy(&attr);
	return r;
}
