/* T6.1: cross-libc load a PROPRIETARY, CLOSED-SOURCE host driver and drive real
 * hardware through it.
 *
 * Everything else measured in this repository is open-source Mesa: the source
 * is available, the build is reproducible, and when something went wrong the
 * __FILE__ strings and a -dbgsym package said where. This one is a vendor
 * binary. It cannot be inspected, cannot be rebuilt, and was linked years ago
 * against a libc nobody here chose. If the fix survives it, it survives the
 * class of library it exists for.
 *
 * The target is NVIDIA's WSL libcuda.so.1, reachable through /dev/dxg
 * paravirtualisation. Its shape is exactly the interesting one:
 *
 *   GLIBC_2.2.5 floor          nothing can need stripping, so the right number
 *                              of rewrites is ZERO (the E39 rule, arriving from
 *                              a vendor binary instead of a synthetic probe)
 *   libdl.so.2 + libpthread.so.0 separate DT_NEEDED edges, i.e. the pre-2.34
 *                              layout: E6/E7's re-homing case, for real
 *   dlopen("libdxcore.so")     a BARE SONAME opened by the host object
 *                              itself, which cross-libc-dlopen deliberately does
 *                              not intercept, so it has to reach ld.so's
 *                              --library-path. Section 7's "do not add library
 *                              searching to the shim" rule, measured.
 *
 * A handle proves ld.so was satisfied. It does not prove the driver works, so
 * this goes all the way: create a context, allocate device memory, push a
 * pattern across to the GPU, pull it back, and compare. If the bytes come back
 * intact then ioctls on /dev/dxg, the vendor's own threading and its allocator
 * all ran correctly under a libc runtime it never saw.
 *
 *      tests/cudaprobe [libcuda.so.1]
 *
 * Exit 0 only on a verified round trip. Anything else is 1, with the reason on
 * stdout, because "it did not work" has to arrive as text a harness can grep
 * and not merely as a status.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The CUDA driver API, declared rather than included: there is no CUDA toolkit
 * in these containers and adding one would make the test about the toolkit.
 * Only the _v2 spellings are used wherever a v1 with a DIFFERENT signature also
 * exists: silently falling back to a v1 that takes `unsigned int *` where the
 * caller passes `size_t *` is exactly the vkprobe bug (section 5), and it would
 * only show itself when the call SUCCEEDS.
 */
typedef int CUresult;
typedef int CUdevice;
typedef unsigned long long CUdeviceptr;
typedef void *CUcontext;
#define CUDA_SUCCESS 0

typedef CUresult (*fn_init)(unsigned int);
typedef CUresult (*fn_drvver)(int *);
typedef CUresult (*fn_devcount)(int *);
typedef CUresult (*fn_devget)(CUdevice *, int);
typedef CUresult (*fn_devname)(char *, int, CUdevice);
typedef CUresult (*fn_devmem)(size_t *, CUdevice);
typedef CUresult (*fn_ctxcreate)(CUcontext *, unsigned int, CUdevice);
typedef CUresult (*fn_ctxdestroy)(CUcontext);
typedef CUresult (*fn_memalloc)(CUdeviceptr *, size_t);
typedef CUresult (*fn_memfree)(CUdeviceptr);
typedef CUresult (*fn_h2d)(CUdeviceptr, const void *, size_t);
typedef CUresult (*fn_d2h)(void *, CUdeviceptr, size_t);
typedef CUresult (*fn_errstr)(CUresult, const char **);

static fn_errstr cu_errstr;

/* The codes this probe can actually produce, named here rather than left to the
 * driver. cuGetErrorString is itself a driver call and returns nothing before
 * cuInit has succeeded, which is exactly the case whose code most needs a name:
 * a bare "cuInit -> 100" in a report is not a finding until someone looks it up.
 */
static const char *cuname(CUresult r) {
	switch (r) {
	case 0:   return "CUDA_SUCCESS";
	case 3:   return "CUDA_ERROR_NOT_INITIALIZED";
	case 100: return "CUDA_ERROR_NO_DEVICE";
	case 101: return "CUDA_ERROR_INVALID_DEVICE";
	case 200: return "CUDA_ERROR_INVALID_IMAGE";
	case 201: return "CUDA_ERROR_INVALID_CONTEXT";
	case 304: return "CUDA_ERROR_OPERATING_SYSTEM";
	case 999: return "CUDA_ERROR_UNKNOWN";
	default:  return "";
	}
}

static const char *cuerr(CUresult r) {
	const char *s = NULL;
	if (cu_errstr && cu_errstr(r, &s) == CUDA_SUCCESS && s) return s;
	return cuname(r);
}

/* dlerror() is destructive and dlsym() clears it, so a miss is reported the
 * moment it happens rather than read back later against a message some other
 * probe has since overwritten (section 5). */
static void *need(void *h, const char *name, int *bad) {
	dlerror();
	void *p = dlsym(h, name);
	if (!p) { printf("  MISSING  %s\n", name); *bad = 1; }
	return p;
}

#define PATTERN_BYTES 4096
#define GUARD 64

int main(int argc, char **argv) {
	/* Block-buffered stdout loses everything printed before a crash when the
	 * output is a pipe, and the crash then looks like it happened first. */
	setvbuf(stdout, NULL, _IONBF, 0);

	const char *lib = argc > 1 ? argv[1] : "/usr/lib/wsl/lib/libcuda.so.1";

	/* RTLD_NOW: bind everything at load time, so an unresolvable symbol is a
	 * dlopen failure naming the symbol and not a jump into nothing much
	 * later. */
	void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
	if (!h) { printf("FAILED: dlopen: %s\n", dlerror()); return 1; }
	printf("  handle          : %p\n", h);

	int bad = 0;
	fn_init       cu_init    = (fn_init)       need(h, "cuInit", &bad);
	fn_drvver     cu_drvver  = (fn_drvver)     need(h, "cuDriverGetVersion", &bad);
	fn_devcount   cu_count   = (fn_devcount)   need(h, "cuDeviceGetCount", &bad);
	fn_devget     cu_devget  = (fn_devget)     need(h, "cuDeviceGet", &bad);
	fn_devname    cu_devname = (fn_devname)    need(h, "cuDeviceGetName", &bad);
	fn_devmem     cu_devmem  = (fn_devmem)     need(h, "cuDeviceTotalMem_v2", &bad);
	fn_ctxcreate  cu_ctxnew  = (fn_ctxcreate)  need(h, "cuCtxCreate_v2", &bad);
	fn_ctxdestroy cu_ctxdel  = (fn_ctxdestroy) need(h, "cuCtxDestroy_v2", &bad);
	fn_memalloc   cu_alloc   = (fn_memalloc)   need(h, "cuMemAlloc_v2", &bad);
	fn_memfree    cu_free    = (fn_memfree)    need(h, "cuMemFree_v2", &bad);
	fn_h2d        cu_h2d     = (fn_h2d)        need(h, "cuMemcpyHtoD_v2", &bad);
	fn_d2h        cu_d2h     = (fn_d2h)        need(h, "cuMemcpyDtoH_v2", &bad);
	cu_errstr = (fn_errstr) dlsym(h, "cuGetErrorString");   /* optional */
	if (bad) { printf("FAILED: the vendor library is missing entry points\n"); return 1; }

	/* Where did it come from? Guards against a bundled or system fallback
	 * being measured instead of the vendor file that was asked for. */
	Dl_info info;
	if (dladdr((void *)cu_init, &info) && info.dli_fname)
		printf("  provenance      : %s\n", info.dli_fname);

	/* cuInit is the first call that actually enters the driver: it opens the
	 * device node and, on WSL, dlopen()s libdxcore.so by BARE SONAME from
	 * inside this host object. */
	CUresult r = cu_init(0);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuInit -> %d %s\n", r, cuerr(r)); return 1; }
	printf("  cuInit          : ok\n");

	int drv = 0;
	if (cu_drvver(&drv) == CUDA_SUCCESS)
		printf("  driver version  : %d.%d\n", drv / 1000, (drv % 1000) / 10);

	int n = -1;
	r = cu_count(&n);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuDeviceGetCount -> %d %s\n", r, cuerr(r)); return 1; }
	printf("  devices         : %d\n", n);
	if (n < 1) { printf("FAILED: no CUDA device\n"); return 1; }

	CUdevice dev = 0;
	r = cu_devget(&dev, 0);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuDeviceGet -> %d %s\n", r, cuerr(r)); return 1; }

	/* A guard band, because the last time a driver wrote into a buffer this
	 * code declared, the overrun only happened when enumeration SUCCEEDED. */
	struct { char name[256]; unsigned char guard[GUARD]; } nb;
	memset(&nb, 0, sizeof nb);
	memset(nb.guard, 0xA5, GUARD);
	if (cu_devname(nb.name, (int)sizeof nb.name, dev) == CUDA_SUCCESS)
		printf("  device[0]       : %.*s\n", (int)sizeof nb.name, nb.name);
	for (int i = 0; i < GUARD; i++)
		if (nb.guard[i] != 0xA5) { printf("FAILED: cuDeviceGetName overran its buffer\n"); return 1; }

	size_t total = 0;
	if (cu_devmem(&total, dev) == CUDA_SUCCESS)
		printf("  device memory   : %llu MiB\n", (unsigned long long)(total >> 20));

	/* --- the round trip ------------------------------------------------ */
	CUcontext ctx = NULL;
	CUdeviceptr dptr = 0;
	unsigned char *out = NULL, *back = NULL;
	int rc = 1;

	r = cu_ctxnew(&ctx, 0, dev);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuCtxCreate -> %d %s\n", r, cuerr(r)); return 1; }

	out = malloc(PATTERN_BYTES);
	back = malloc(PATTERN_BYTES);
	if (!out || !back) { printf("FAILED: out of host memory\n"); goto done; }
	for (int i = 0; i < PATTERN_BYTES; i++) out[i] = (unsigned char)(i * 31 + 7);
	memset(back, 0, PATTERN_BYTES);

	r = cu_alloc(&dptr, PATTERN_BYTES);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuMemAlloc -> %d %s\n", r, cuerr(r)); goto done; }
	r = cu_h2d(dptr, out, PATTERN_BYTES);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuMemcpyHtoD -> %d %s\n", r, cuerr(r)); goto done; }
	r = cu_d2h(back, dptr, PATTERN_BYTES);
	if (r != CUDA_SUCCESS) { printf("FAILED: cuMemcpyDtoH -> %d %s\n", r, cuerr(r)); goto done; }
	if (memcmp(out, back, PATTERN_BYTES) != 0) {
		printf("FAILED: %d bytes went to the GPU and came back DIFFERENT\n", PATTERN_BYTES);
		goto done;
	}
	printf("OK: %d CUDA device(s), %d bytes round-tripped through the GPU and verified\n",
	       n, PATTERN_BYTES);
	rc = 0;

done:
	if (dptr) cu_free(dptr);
	if (ctx)  cu_ctxdel(ctx);
	free(out);
	free(back);
	return rc;
}
