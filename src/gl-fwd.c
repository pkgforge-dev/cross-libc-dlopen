/* gl-fwd.c: stand in for one bundled dispatcher whose plugin the host lacks.
 *
 * THE SHAPE OF THE BUG. Vulkan survives a foreign-libc host because its
 * loader/driver boundary is thin and universal: the bundled libvulkan.so.1
 * dlopens the host's ICD, which exposes one entry point, and cross-libc-dlopen.so
 * carries that one object across the libc gap. OpenGL has no such boundary on
 * every host. The AppImage bundles libglvnd, whose libGL.so.1 is a DISPATCHER
 * that dlopens a VENDOR library (libGLX_mesa.so.0), and a host whose Mesa was
 * built without glvnd ships no vendor library at all. That is every musl distro
 * and every pre-glvnd glibc distro (Ubuntu 14.04, Debian 8). There the bundled
 * dispatcher has nothing to dispatch to, glXChooseVisual returns NULL, and the
 * application prints "couldn't get an RGB, Double-buffered visual", a message
 * about visuals, for a fault that is about neither visuals nor libc.
 *
 * THE REPAIR. Replace the dispatcher rather than supply the missing plugin.
 * This object is built with the SONAME of the library it replaces, so ld.so
 * binds an application's DT_NEEDED to it and never loads the bundled one. Its
 * constructor picks a target and every entry point tail-jumps there:
 *
 *   - classic-Mesa host: the host's own libGL.so.1, loaded through
 *     cross-libc-dlopen.so, which strips version tags, drops the musl libc edge
 *     and bridges the remaining imports. RTLD_GLOBAL, because that is the
 *     shape a DT_NEEDED libGL has natively and classic Mesa's DRI driver
 *     relies on it (see glfwd_open_target).
 *   - glvnd host: the BUNDLED dispatcher, which works there. The shim becomes
 *     one extra jump and nothing else changes.
 *
 * WHY THE TABLE IS GENERATED. A shim that replaces a library must export
 * everything that library exports; anything less is `undefined symbol` for the
 * first application that links a name outside the list. The bundled libGL.so.1
 * exports 3470 entry points. So the list is READ OUT of the object being
 * replaced by tools/gen_gl_fwd.py, and `make gl-syms-check` fails the build if
 * the checked-in table drifts from it.
 *
 * WHY TRAMPOLINES AND NOT WRAPPERS. Each entry point is a tail jump through a
 * table slot, not a C function with a hand-written prototype. A tail jump
 * preserves every argument register, the return value and the varargs count in
 * %al, so it forwards ANY signature correctly, including the ones nobody
 * typed out. A hand-written prototype that disagrees with the real one corrupts
 * arguments silently, and with 3470 entry points that class of bug is not worth
 * carrying. The cost is that a trampoline forwards a CALL: exported data
 * objects cannot be forwarded, and the generator says so.
 *
 * Ahead of the jump each trampoline loads its own index into a scratch
 * register, which is what lets an UNRESOLVED slot reach code that knows which
 * entry point was called. See the block above glfwd_resolve_asm below; it is
 * the reason the host stack loads on first use rather than in a constructor,
 * and the reason an entry point the host cannot provide is a line rather than
 * a silent zero.
 *
 * THE SAME SOURCE FILE IS BUILT THREE TIMES, as gl-fwd.so, egl-fwd.so and
 * gles-fwd.so, differing only in the generated table and the vendor marker
 * its dispatcher looks for. See src/Makefile.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The one /etc/ld.so.conf walk, shared with src/runtime-select.c. */
#include "ld-conf.h"
#include "cld-env.h"

#ifndef GLFWD_TABLE
#error "build with -DGLFWD_TABLE=... naming a generated table (see src/Makefile)"
#endif

/* GLFWD_SONAME, GLFWD_COUNT and one GLFWD_SYM(index, name) per entry point.
 * Included several times below with GLFWD_SYM defined differently each time. */
#define GLFWD_SYM(i, n)
#include GLFWD_TABLE
#undef GLFWD_SYM

#ifndef GLFWD_TAG
#define GLFWD_TAG "gl-fwd.so"
#endif
/* The bundled dispatcher looks for a vendor library with this prefix/suffix;
 * its presence on the host is what says the bundled one can still work. */
#ifndef GLFWD_VENDOR_PREFIX
#define GLFWD_VENDOR_PREFIX "libGLX_"
#endif
#ifndef GLFWD_VENDOR_SUFFIX
#define GLFWD_VENDOR_SUFFIX ".so.0"
#endif
/* A directory whose mere non-emptiness also proves a vendor exists, or NULL. */
#ifndef GLFWD_VENDOR_DIR
#define GLFWD_VENDOR_DIR NULL
#endif
/* The API's own extension-resolution entry point. Half of what a glvnd libGL
 * exports is extension entry points that a classic Mesa libGL implements but
 * does not put in .dynsym: the designed way to reach those has always been
 * glXGetProcAddress, so a name dlsym cannot find is asked for that way before
 * it is given up on. Measured on Alpine: 1357 of 3470 by dlsym alone. */
#ifndef GLFWD_GETPROC
#define GLFWD_GETPROC "glXGetProcAddressARB"
#endif

#if defined(__x86_64__)
#  define GLFWD_TRIPLET "x86_64-linux-gnu"
#elif defined(__aarch64__)
#  define GLFWD_TRIPLET "aarch64-linux-gnu"
#elif defined(__i386__)
#  define GLFWD_TRIPLET "i386-linux-gnu"
#else
#  define GLFWD_TRIPLET "unknown"
#endif

static int glfwd_debug(void) {
	const char *v = cld_getenv("CROSS_LIBC_DLOPEN_DEBUG", NULL);
	return v && strcmp(v, "1") == 0;
}

/* Trace implies debug: a trace with the logger switched off prints nothing,
 * which is a confusing way to answer a question somebody asked for. */
static int glfwd_trace(void) {
	const char *v = cld_getenv("CROSS_LIBC_DLOPEN_GL_TRACE", NULL);
	return v && strcmp(v, "1") == 0;
}

static void glfwd_log(const char *fmt, ...) {
	if (!glfwd_debug() && !glfwd_trace())
		return;
	va_list ap;
	va_start(ap, fmt);
	fputs(" [" GLFWD_TAG "] >> ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* ------------------------------------------------------------ trampolines */
/*
 * glfwd_absent is where an entry point the target does not provide lands. It
 * returns zero in both return registers, which is the right shape for the void,
 * integer and pointer cases and wrong only for a float return, a case that
 * cannot arise without the target also being wrong. Jumping through a NULL slot
 * instead would be a crash inside a GL call with no explanation, so every slot
 * is initialised to this before anything is resolved.
 */
extern void glfwd_absent(void) __attribute__((visibility("hidden")));

/*
 * glfwd_resolve_asm is the other thing a slot can hold, and it is why a slot
 * can now do something a plain address cannot: RUN CODE at the first call of
 * one particular entry point.
 *
 * The problem it solves. A table slot is an address; whoever jumps through it
 * arrives with no idea WHICH slot they came from, so the old design had to
 * decide every entry point's fate in a constructor, either a real address or a
 * silent zero-returning stub, before the application had asked for anything.
 * That forced two things this file used to carry as defects: the host GL stack
 * was loaded in every process whether or not it would ever be used, and an
 * entry point the host does not implement was indistinguishable, from outside,
 * from one that worked and returned zero.
 *
 * The repair is the index. Each trampoline knows its own index at ASSEMBLY
 * time, so it loads it into a register the ABI already allows a call to
 * destroy: %r11 on x86-64, the register the PLT itself clobbers; x17/IP1 on
 * aarch64, which is reserved for exactly this class of veneer. It then
 * jumps through the slot as before. A resolved slot ignores it. An unresolved
 * slot points here, and here the index is the whole message.
 *
 * What this costs the fast path is one immediate load per call, on a path that
 * is about to enter a graphics driver. What it buys is B1 and B4.
 *
 * This is _dl_runtime_resolve minus the bookkeeping: save everything an
 * argument can arrive in, call a C function, put it all back, tail-jump to
 * whatever it decided. The saved set is the SysV argument registers plus %rax
 * (the varargs float count) and %r10 (the static chain, which glibc's own
 * trampoline does not preserve and which costs 8 bytes to get right).
 */
extern void glfwd_resolve_asm(void) __attribute__((visibility("hidden")));
__attribute__((visibility("hidden"))) void *glfwd_resolve_one(int index);

#if defined(__x86_64__)
/* endbr64 is spelled as bytes so the floor's assembler cannot be too old for
 * it, and it is present because an application built with indirect-branch
 * tracking reaches these through a PLT, which is an indirect jump. */
__asm__(".text\n"
        ".globl  glfwd_absent\n"
        ".hidden glfwd_absent\n"
        ".type   glfwd_absent,@function\n"
        "glfwd_absent:\n"
        "	.byte 0xf3,0x0f,0x1e,0xfa\n"
        "	pxor %xmm0, %xmm0\n"
        "	xor  %eax, %eax\n"
        "	ret\n"
        ".size glfwd_absent, .-glfwd_absent\n");
/*
 * `and $-16,%rsp` after saving %rbp is what makes the alignment unconditional
 * rather than argued: the ABI says %rsp+8 is 16-aligned on entry, but a
 * trampoline is reached from anywhere and the movaps below FAULT on a
 * misaligned address. %rbp restores the caller's %rsp whatever it was.
 * The C resolver is hidden, so `call` is PC-relative and cannot be preempted
 * into some other object's idea of what resolving means.
 */
__asm__(".text\n"
        ".globl  glfwd_resolve_asm\n"
        ".hidden glfwd_resolve_asm\n"
        ".type   glfwd_resolve_asm,@function\n"
        "glfwd_resolve_asm:\n"
        "	.byte 0xf3,0x0f,0x1e,0xfa\n"
        "	push %rbp\n"
        "	mov  %rsp, %rbp\n"
        "	and  $-16, %rsp\n"
        "	sub  $192, %rsp\n"
        "	mov  %rax,    0(%rsp)\n"
        "	mov  %rdi,    8(%rsp)\n"
        "	mov  %rsi,   16(%rsp)\n"
        "	mov  %rdx,   24(%rsp)\n"
        "	mov  %rcx,   32(%rsp)\n"
        "	mov  %r8,    40(%rsp)\n"
        "	mov  %r9,    48(%rsp)\n"
        "	mov  %r10,   56(%rsp)\n"
        "	movaps %xmm0, 64(%rsp)\n"
        "	movaps %xmm1, 80(%rsp)\n"
        "	movaps %xmm2, 96(%rsp)\n"
        "	movaps %xmm3,112(%rsp)\n"
        "	movaps %xmm4,128(%rsp)\n"
        "	movaps %xmm5,144(%rsp)\n"
        "	movaps %xmm6,160(%rsp)\n"
        "	movaps %xmm7,176(%rsp)\n"
        "	mov  %r11d, %edi\n"
        "	call glfwd_resolve_one\n"
        "	mov  %rax, %r11\n"
        "	movaps 64(%rsp), %xmm0\n"
        "	movaps 80(%rsp), %xmm1\n"
        "	movaps 96(%rsp), %xmm2\n"
        "	movaps 112(%rsp),%xmm3\n"
        "	movaps 128(%rsp),%xmm4\n"
        "	movaps 144(%rsp),%xmm5\n"
        "	movaps 160(%rsp),%xmm6\n"
        "	movaps 176(%rsp),%xmm7\n"
        "	mov     0(%rsp), %rax\n"
        "	mov     8(%rsp), %rdi\n"
        "	mov    16(%rsp), %rsi\n"
        "	mov    24(%rsp), %rdx\n"
        "	mov    32(%rsp), %rcx\n"
        "	mov    40(%rsp), %r8\n"
        "	mov    48(%rsp), %r9\n"
        "	mov    56(%rsp), %r10\n"
        "	mov  %rbp, %rsp\n"
        "	pop  %rbp\n"
        "	jmp  *%r11\n"
        ".size glfwd_resolve_asm, .-glfwd_resolve_asm\n");
/* No prologue: the callee sees the caller's registers and stack exactly as they
 * were, so the signature never has to be known here. %r11 is the one register
 * the SysV ABI lets a PLT destroy, which is precisely what makes it free to
 * carry the index through a call boundary. */
#define GLFWD_TRAMPOLINE(i, n)                                                     \
	__asm__(".text\n"                                                         \
	        ".globl " #n "\n"                                                 \
	        ".type " #n ",@function\n"                                        \
	        ".p2align 4\n"                                                    \
	        #n ":\n"                                                          \
	        "	.byte 0xf3,0x0f,0x1e,0xfa\n"                                  \
	        "	mov $" #i ", %r11d\n"                                         \
	        "	jmp *glfwd_tab+8*" #i "(%rip)\n"                              \
	        ".size " #n ", .-" #n "\n");
#elif defined(__aarch64__)
/* Assembled here, and RUN under qemu-user on an aarch64 image. See
 * `make gl-fwd-qemu-check` and ../docs/report/10-measured-versus-assumed.md 10. Not run on aarch64 silicon. */
__asm__(".text\n"
        ".globl  glfwd_absent\n"
        ".hidden glfwd_absent\n"
        ".type   glfwd_absent,%function\n"
        "glfwd_absent:\n"
        "	hint #34\n"
        "	mov  x0, #0\n"
        "	movi d0, #0\n"
        "	ret\n"
        ".size glfwd_absent, .-glfwd_absent\n");
/* x0-x7 are the argument registers, x8 the indirect-result pointer, q0-q7 the
 * floating-point arguments, and x30 the return address a `bl` would destroy.
 * x9-x15 are caller-saved and carry no argument, so they are not saved. */
__asm__(".text\n"
        ".globl  glfwd_resolve_asm\n"
        ".hidden glfwd_resolve_asm\n"
        ".type   glfwd_resolve_asm,%function\n"
        "glfwd_resolve_asm:\n"
        "	hint #34\n"
        "	stp x29, x30, [sp, #-16]!\n"
        "	mov x29, sp\n"
        "	sub sp, sp, #208\n"
        "	stp q0, q1, [sp, #0]\n"
        "	stp q2, q3, [sp, #32]\n"
        "	stp q4, q5, [sp, #64]\n"
        "	stp q6, q7, [sp, #96]\n"
        "	stp x0, x1, [sp, #128]\n"
        "	stp x2, x3, [sp, #144]\n"
        "	stp x4, x5, [sp, #160]\n"
        "	stp x6, x7, [sp, #176]\n"
        "	str x8, [sp, #192]\n"
        "	mov w0, w17\n"
        "	bl  glfwd_resolve_one\n"
        "	mov x16, x0\n"
        "	ldp q0, q1, [sp, #0]\n"
        "	ldp q2, q3, [sp, #32]\n"
        "	ldp q4, q5, [sp, #64]\n"
        "	ldp q6, q7, [sp, #96]\n"
        "	ldp x0, x1, [sp, #128]\n"
        "	ldp x2, x3, [sp, #144]\n"
        "	ldp x4, x5, [sp, #160]\n"
        "	ldp x6, x7, [sp, #176]\n"
        "	ldr x8, [sp, #192]\n"
        "	add sp, sp, #208\n"
        "	ldp x29, x30, [sp], #16\n"
        "	br  x16\n"
        ".size glfwd_resolve_asm, .-glfwd_resolve_asm\n");
/* x16 was already the branch register, so the index rides in x17. Both are the
 * intra-procedure-call scratch registers, which exist to be destroyed by
 * exactly this kind of veneer. */
#define GLFWD_TRAMPOLINE(i, n)                                                     \
	__asm__(".text\n"                                                         \
	        ".globl " #n "\n"                                                 \
	        ".type " #n ",%function\n"                                        \
	        ".p2align 4\n"                                                    \
	        #n ":\n"                                                          \
	        "	hint #34\n"                                                   \
	        "	mov  w17, #" #i "\n"                                          \
	        "	adrp x16, glfwd_tab+8*" #i "\n"                               \
	        "	ldr  x16, [x16, #:lo12:glfwd_tab+8*" #i "]\n"                 \
	        "	br   x16\n"                                                   \
	        ".size " #n ", .-" #n "\n");
#else
#error "gl-fwd needs a tail-jump trampoline for this architecture"
#endif

/* Hidden, so the trampolines reach it PC-relative with no GOT hop and with no
 * chance of another object preempting the table out from under them.
 *
 * Every slot starts at the resolver, not at an address: nothing is decided
 * until the application calls something. A slot is written exactly once, by
 * the first call to that name, and after that the trampoline is the same two
 * useful instructions it always was. */
__attribute__((visibility("hidden"))) void *glfwd_tab[GLFWD_COUNT] = {
#define GLFWD_SYM(i, n) [i] = (void *)(void (*)(void))glfwd_resolve_asm,
#include GLFWD_TABLE
#undef GLFWD_SYM
};

/* What dlsym said, once, when the target loaded: the address or NULL. Separate
 * from glfwd_tab because they answer different questions. This one is "can
 * this host do X at all", asked once for all GLFWD_COUNT names in a single
 * pass; glfwd_tab is "has anything called X yet", which is what makes the
 * absent case observable (B1) and the call count measurable (B6). Keeping the
 * pass single is also what keeps the dlerror() damage to one moment. See
 * glfwd_fill_addr. */
static void **glfwd_addr;

/* Emit the trampolines. The arch-specific macro is bound to GLFWD_SYM only for
 * the length of this include: leaving it bound would silently win over the
 * next expansion of the same table, which is exactly what it did once. */
#define GLFWD_SYM(i, n) GLFWD_TRAMPOLINE(i, n)
#include GLFWD_TABLE
#undef GLFWD_SYM

static const char *const glfwd_names[GLFWD_COUNT] = {
#define GLFWD_SYM(i, n) [i] = #n,
#include GLFWD_TABLE
#undef GLFWD_SYM
};

/* ------------------------------------------------------------- discovery */
/*
 * This is a SINGLE-SONAME lookup, not a library search. ld.so cannot answer it
 * because the name is taken by this object, so it is answered here, for exactly
 * one name. Nothing here ever opens a library it was not handed by name, which
 * is the rule cross-libc-dlopen.c keeps.
 *
 * WHERE IT LOOKS, IN ORDER, AND WHY THE ORDER CHANGED.
 *
 *   1. CROSS_LIBC_DLOPEN_GL_HOST_DIR. The explicit handoff. A launcher that has already
 *      assembled the host library path, as sharun does from the ld.so cache,
 *      can hand it straight here and nothing below is consulted for the answer
 *      it gives.
 *   2. every directory /etc/ld.so.conf and its includes name (ld-conf.h).
 *      THE HOST'S OWN ANSWER, and the repair for a defect reported from
 *      outside by @Samueru-sama: classic libGL.so.1 lives in
 *      <triplet>/mesa on Ubuntu's alternatives layout and classic libEGL.so.1
 *      in <triplet>/mesa-egl, the hardcoded list below had the first and not
 *      the second, and EGL therefore failed on every pre-glvnd Ubuntu while GL
 *      worked. That is not a missing entry, it is what a hardcoded guess about
 *      somebody else's packaging is FOR: it drifts, silently, and only on the
 *      hosts nobody has. The host writes the answer down in
 *      /etc/ld.so.conf.d/x86_64-linux-gnu_EGL.conf; reading it is the fix.
 *   3. the conventional directories, below. Still needed, and not a fallback
 *      in name only: musl distros have no /etc/ld.so.conf at all, and Alpine
 *      uses /etc/ld-musl-<arch>.path, so on the very host class this shim
 *      exists for, list 3 is the only one of the three that answers.
 *
 * PR #4's mesa-egl entries are kept in list 3 for the same reason: a host with
 * the alternatives layout and no readable ld.so.conf is not hypothetical, and
 * an access() that misses costs nothing.
 */
static const char *const glfwd_host_dirs[] = {
	"/usr/lib/" GLFWD_TRIPLET, "/lib/" GLFWD_TRIPLET,
	"/usr/lib/" GLFWD_TRIPLET "/mesa", "/usr/lib/" GLFWD_TRIPLET "/mesa-egl",
	"/usr/lib64", "/lib64", "/usr/lib64/mesa", "/usr/lib64/mesa-egl",
	"/usr/lib", "/lib", "/usr/lib/mesa", "/usr/lib/mesa-egl",
	"/usr/local/lib", "/usr/local/lib64",
	NULL
};

/* ld-conf.h hands warnings back as two fixed strings so it can stay ignorant
 * of any caller's logger. */
static void glfwd_conf_warn(void *ctx, const char *what, const char *detail) {
	(void)ctx;
	glfwd_log("/etc/ld.so.conf: %s%s%s\n", what, detail ? ": " : "",
	          detail ? detail : "");
}

/* Call fn(dir) for every candidate directory until it returns non-zero. */
static int glfwd_each_dir(int (*fn)(const char *dir, void *ctx), void *ctx) {
	const char *env = cld_getenv("CROSS_LIBC_DLOPEN_GL_HOST_DIR", NULL);
	if (env && *env) {
		char *copy = strdup(env);
		if (copy) {
			for (char *p = strtok(copy, ":"); p; p = strtok(NULL, ":")) {
				if (*p == '/' && fn(p, ctx)) {
					free(copy);
					return 1;
				}
			}
			free(copy);
		}
	}
	if (ldconf_each_dir("/etc/ld.so.conf", fn, glfwd_conf_warn, ctx))
		return 1;
	for (size_t i = 0; glfwd_host_dirs[i]; i++)
		if (fn(glfwd_host_dirs[i], ctx))
			return 1;
	return 0;
}

static int glfwd_try_soname(const char *dir, void *ctx) {
	char *out = ctx;
	char path[PATH_MAX];
	if (snprintf(path, sizeof path, "%s/%s", dir, GLFWD_SONAME) >= (int)sizeof path)
		return 0;
	if (access(path, R_OK) != 0)
		return 0;
	snprintf(out, PATH_MAX, "%s", path);
	return 1;
}

static int glfwd_try_vendor(const char *dir, void *ctx) {
	(void)ctx;
	DIR *d = opendir(dir);
	if (!d)
		return 0;
	int found = 0;
	struct dirent *de;
	size_t plen = strlen(GLFWD_VENDOR_PREFIX), slen = strlen(GLFWD_VENDOR_SUFFIX);
	while (!found && (de = readdir(d)) != NULL) {
		size_t n = strlen(de->d_name);
		if (n > plen + slen &&
		    strncmp(de->d_name, GLFWD_VENDOR_PREFIX, plen) == 0 &&
		    strcmp(de->d_name + n - slen, GLFWD_VENDOR_SUFFIX) == 0)
			found = 1;
	}
	closedir(d);
	return found;
}

/* Is there anything in this directory the bundled dispatcher could dispatch to?
 * Two markers, because the two dispatchers look for different things: GL wants
 * a libGLX_<vendor>.so.0, EGL and GLES want a JSON file in a vendor directory. */
static int glfwd_vendor_in(const char *libdir, const char *vendordir) {
	if (vendordir) {
		DIR *d = opendir(vendordir);
		if (d) {
			struct dirent *de;
			while ((de = readdir(d)) != NULL) {
				if (de->d_name[0] == '.')
					continue;
				glfwd_log("vendor found: %s/%s\n", vendordir, de->d_name);
				closedir(d);
				return 1;
			}
			closedir(d);
		}
	}
	return libdir ? glfwd_try_vendor(libdir, NULL) : 0;
}

/*
 * Does the BUNDLE carry its own vendor library?
 *
 * ⚠ THIS QUESTION WAS MISSING, and a real application is what found it. The
 * check used to ask only about the HOST, which is right for an AppImage built
 * to use host drivers, which bundles a dispatcher and no vendor, so if the host
 * has no vendor either there is nothing to dispatch to and the host's own
 * libGL is the only way forward. It is wrong for a SELF-CONTAINED AppImage,
 * which bundles its whole Mesa: gtk4-demo ships libEGL_mesa.so.0 and 271 other
 * libraries, the host-only check saw musl Alpine's empty vendor directory,
 * concluded "no vendor anywhere", and forwarded a bundled GTK4 onto Alpine's
 * Mesa. Two Mesas, one process, SIGFPE. With no shim in .preload the same
 * AppImage runs fine, which is what made it a shim bug rather than a host one.
 *
 * The bundle wins when it has one: it is the stack the AppImage was built and
 * tested against, and preferring it is also what makes this shim safe to put
 * in EVERY AppImage's .preload rather than only in the host-drivers ones.
 */
static int glfwd_bundle_has_vendor(void) {
	const char *appdir = cld_root();
	if (!appdir || !*appdir)
		return 0;
	char libdir[PATH_MAX], vdir[PATH_MAX];
	snprintf(libdir, sizeof libdir, "%s/%s", appdir, cld_libdir());
	const char *hostv = GLFWD_VENDOR_DIR;
	if (hostv) {
		/* The bundled counterpart of the host's vendor directory: the same
		 * path with the AppDir's prefix in front of it, which is where sharun
		 * puts it. "/usr/share/..." -> "<appdir>/share/...". */
		const char *rel = hostv;
		if (strncmp(rel, "/usr/", 5) == 0)
			rel += 4;
		snprintf(vdir, sizeof vdir, "%s%s", appdir, rel);
	}
	return glfwd_vendor_in(libdir, hostv ? vdir : NULL);
}

/* Does the host carry a plugin the BUNDLED dispatcher could still use? */
static int glfwd_host_has_vendor(void) {
	const char *vdir = GLFWD_VENDOR_DIR;
	if (vdir && glfwd_vendor_in(NULL, vdir))
		return 1;
	return glfwd_each_dir(glfwd_try_vendor, NULL);
}

/* --------------------------------------------------------------- the load */

static void *glfwd_open_target(const char **how) {
	/* cross-libc-dlopen.so preloads the bundled libc runtime set into the global
	 * scope, and a host object whose musl libc edge was dropped needs that set
	 * to be there BEFORE it is loaded. Preload constructors run in REVERSE of
	 * the .preload order (measured in E56), so this object's constructor runs
	 * FIRST when it is listed last, which is the wrong way round. Rather than
	 * depend on a loader ordering nobody documents, ask for it. */
	void (*ready)(void) =
	    (void (*)(void))(uintptr_t)dlsym(RTLD_DEFAULT, "cross_libc_dlopen_init_now");
	if (!ready)
		/* An older shim in the same process still answers to its old name.
		 * Belt and braces since the shim went lazy (REPORT 9.6), but free. */
		ready = (void (*)(void))(uintptr_t)dlsym(RTLD_DEFAULT, "foreign_dlopen_init_now");
	if (ready)
		ready();
	else
		glfwd_log("cross-libc-dlopen.so is not in this process; a host library "
		          "built against another libc will not load\n");
	dlerror();                                  /* a miss above left a message */

	const char *want = cld_getenv("CROSS_LIBC_DLOPEN_GL_TARGET", NULL);
	int force_host    = want && strcmp(want, "host") == 0;
	int force_bundled = want && strcmp(want, "bundled") == 0;

	char bundled[PATH_MAX];
	const char *appdir = cld_root();
	int have_bundled = 0;
	if (appdir && *appdir) {
		snprintf(bundled, sizeof bundled, "%s/%s/%s", appdir, cld_libdir(), GLFWD_SONAME);
		have_bundled = access(bundled, R_OK) == 0;
	}

	/* The bundle's own vendor is asked about FIRST and separately, because the
	 * two answers mean different things: "the bundle can stand on its own" is
	 * a reason to leave it alone, while "the host has a vendor" is only a
	 * reason to believe the bundled dispatcher will find something. */
	int bundle_vendor = !force_host && have_bundled && glfwd_bundle_has_vendor();
	int host_vendor   = !force_host && have_bundled && !bundle_vendor &&
	                    glfwd_host_has_vendor();
	int use_bundled = force_bundled || bundle_vendor || host_vendor;
	if (use_bundled && have_bundled) {
		/* RTLD_GLOBAL so the dispatcher's whole export table reaches the global
		 * scope: the entry points this shim does not own must still resolve. */
		void *h = dlopen(bundled, RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE);
		if (h) {
			/* Which of the two reasons, because they are not the same claim:
			 * one says the AppImage is self-contained, the other says the host
			 * can serve it. Reporting both as "the host has a vendor library"
			 * is how a self-contained AppImage looked like a host one. */
			*how = bundle_vendor
			           ? "bundled dispatcher (the BUNDLE has its own vendor "
			             "library; the AppImage is self-contained)"
			       : host_vendor
			           ? "bundled dispatcher (the host has a vendor library)"
			           : "bundled dispatcher (forced)";
			glfwd_log("target %s -- %s\n", bundled, *how);
			return h;
		}
		glfwd_log("bundled %s present but would not load: %s\n",
		          bundled, dlerror());
	}

	char host[PATH_MAX];
	host[0] = '\0';
	if (!force_bundled && glfwd_each_dir(glfwd_try_soname, host)) {
		/* RTLD_GLOBAL is the point here, not a detail. Natively an
		 * application's DT_NEEDED libGL.so.1 sits in the global scope, and
		 * classic Mesa's DRI driver imports _glapi_* with NO DT_NEEDED edge on
		 * libglapi.so.0: it expects to find them there because libGL pulled
		 * libglapi in. Loaded RTLD_LOCAL that linkage is invisible and the
		 * driver dies with "undefined symbol: _glapi_tls_Dispatch". Asking for
		 * it HERE, for this one object, reproduces the native shape; making
		 * EVERY cross-libc dlopen global would additionally hand host definitions
		 * a win over bundled ones that they do not have natively either. */
		void *h = dlopen(host, RTLD_LAZY | RTLD_GLOBAL);
		if (h) {
			*how = "host library (no vendor library for the bundled one)";
			glfwd_log("target %s -- %s\n", host, *how);
			return h;
		}
		glfwd_log("host %s would not load: %s\n", host, dlerror());
	}

	if (!use_bundled && have_bundled) {
		void *h = dlopen(bundled, RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE);
		if (h) {
			*how = "bundled dispatcher (nothing better on this host)";
			glfwd_log("target %s -- %s\n", bundled, *how);
			return h;
		}
	}
	*how = "nothing";
	return NULL;
}

/* ------------------------------------------------- resolution, on first call */
/*
 * B4: nothing below here runs until the application calls a GL entry point.
 * A process that links this shim and never draws, such as a Vulkan-only binary
 * in an AppDir that also ships a GL one, pays for the mapping of this object
 * and nothing else. Measured cost of the old eager constructor, and therefore
 * of what this removes, is in ../docs/report/09-the-second-boundary.md 9.9.
 */

static void *glfwd_target;                 /* the object every slot forwards to */
static const char *glfwd_how = "nothing";
static int glfwd_resolved_count = -1;      /* -1 until the one dlsym pass runs */

/* 0 untried, 1 a thread is inside the load, 2 done. Plain ints with explicit
 * atomics rather than a mutex: pthread_mutex_lock lives in libpthread on the
 * glibc 2.31 floor this is built against, and a shim is a bad place to acquire
 * a new DT_NEEDED. */
static int glfwd_load_state;
/* The load can re-enter this file on the SAME thread: the host GL stack's own
 * constructors run inside our dlopen, this shim preempts the soname they were
 * linked against, and a constructor that calls one of its own entry points
 * arrives back here. Waiting for ourselves would be a hang; TLS turns it into
 * one zero-returning call. */
static __thread int glfwd_in_load;

static void glfwd_load_target(void) {
	const char *how = "nothing";
	void *target = glfwd_open_target(&how);
	if (!target) {
		/* Every slot still resolves to glfwd_absent, so GL calls return zero
		 * and the application prints its own documented failure instead of
		 * crashing through a NULL. Say so: "no vendor" and "no host library"
		 * produce the same message from the application. */
		glfwd_log("%s: no target; all %d entry points return zero\n",
		          GLFWD_SONAME, (int)GLFWD_COUNT);
		dlerror();
		return;
	}

	/* REFUSE TO FORWARD TO OURSELVES.
	 *
	 * This object's SONAME is the one it is impersonating, so if anything ever
	 * resolves that name back to this object, whether ld.so matching a request
	 * against our own libname list, an CROSS_LIBC_DLOPEN_GL_HOST_DIR pointing at the
	 * preload's own directory, or a future glibc that dedups by SONAME after
	 * load, every trampoline would jump to itself. That is an unbounded recursion
	 * inside the first GL call, with no message and a stack overflow for a
	 * diagnostic. It costs one dladdr to make it a sentence instead.
	 *
	 * dladdr rather than comparing handles: the handle for a path and the
	 * handle for a soname can differ for the same object, and the question here
	 * is which FILE the addresses land in. */
	Dl_info self, tgt;
	void *probe = dlsym(target, glfwd_names[0]);
	if (probe && dladdr((void *)(uintptr_t)glfwd_absent, &self) && dladdr(probe, &tgt) &&
	    self.dli_fbase == tgt.dli_fbase) {
		glfwd_log("%s: the target resolves back to this shim (%s); refusing to "
		          "forward to ourselves, all %d entry points return zero\n",
		          GLFWD_SONAME, tgt.dli_fname ? tgt.dli_fname : "?",
		          (int)GLFWD_COUNT);
		dlerror();
		return;
	}
	dlerror();

	glfwd_target = target;
	glfwd_how = how;
}

/*
 * One pass, once, over every name. The reason it is one pass rather than
 * a dlsym per first call is dlerror().
 *
 * dlsym leaves a message behind on every miss, and reading dlerror() to clear
 * it is destructive: whatever the APPLICATION had pending is gone. Resolving
 * lazily per name would put that theft inside an arbitrary GL call, once per
 * absent name. Doing the whole table in one pass confines it to a single
 * moment, the first GL call in the process, and says so under debug when
 * something was actually taken.
 */
static void glfwd_fill_addr(void) {
	glfwd_addr = calloc(GLFWD_COUNT, sizeof *glfwd_addr);
	if (!glfwd_addr) {
		glfwd_log("%s: out of memory for the resolution table; every entry "
		          "point returns zero\n", GLFWD_SONAME);
		return;
	}
	if (!glfwd_target) {
		/* No target: nothing is resolvable, and saying so as 0 keeps the exit
		 * report from printing the -1 that means "never asked". */
		glfwd_resolved_count = 0;
		return;
	}

	/* Read the pending message BEFORE the pass, not after.
	 *
	 * After the pass, dlerror() returns OUR last dlsym miss, and reporting
	 * that as "the message we consumed" is a diagnostic that lies: it names a
	 * symbol the application never asked for. Read first and the string is
	 * genuinely whatever the application had outstanding, and reading it is what
	 * destroys it, and there is no API to put it back, so the only honest
	 * thing left is to say what was taken. */
	const char *stolen = dlerror();
	if (stolen)
		glfwd_log("note: resolving is about to consume a pending dlerror() "
		          "the application had not read -- \"%s\". dlsym's message "
		          "cannot be put back; this is the one moment in the process "
		          "where that can happen\n", stolen);

	/* Read as a pointer, called as a function: forbidden by C, required by
	 * POSIX, and the cast through a union is how you say so without inviting
	 * -Wpedantic to argue about it. */
	union { void *p; void *(*fn)(const unsigned char *); } getproc;
	getproc.p = dlsym(glfwd_target, GLFWD_GETPROC);

	int got = 0, via_dlsym = 0, via_getproc = 0;
	for (int i = 0; i < (int)GLFWD_COUNT; i++) {
		void *p = dlsym(glfwd_target, glfwd_names[i]);
		if (p) {
			via_dlsym++;
		} else if (getproc.fn) {
			/* An extension entry point the implementation has but does not
			 * export. Native code reaches these exactly this way. */
			p = getproc.fn((const unsigned char *)glfwd_names[i]);
			if (p)
				via_getproc++;
		}
		if (p) {
			glfwd_addr[i] = p;
			got++;
		}
	}
	/* Our own last miss, cleared so the application's next dlerror() is clean. */
	dlerror();

	glfwd_resolved_count = got;
	glfwd_log("%s: %d of %d entry points resolved from the %s "
	          "(%d exported, %d via " GLFWD_GETPROC ", %d absent)\n",
	          GLFWD_SONAME, got, (int)GLFWD_COUNT, glfwd_how,
	          via_dlsym, via_getproc, (int)GLFWD_COUNT - got);
	if (got == 0 && glfwd_target)
		glfwd_log("%s: NOT FORWARDED: the target loaded but provided none of "
		          "the %d entry points, so every call returns zero\n",
		          GLFWD_SONAME, (int)GLFWD_COUNT);
}

/* Returns 0 only when this thread is already inside the load. */
static int glfwd_ensure_target(void) {
	if (__atomic_load_n(&glfwd_load_state, __ATOMIC_ACQUIRE) == 2)
		return 1;
	if (glfwd_in_load)
		return 0;

	int expect = 0;
	if (__atomic_compare_exchange_n(&glfwd_load_state, &expect, 1, 0,
	                                __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
		glfwd_in_load = 1;
		glfwd_load_target();
		glfwd_fill_addr();
		glfwd_in_load = 0;
		__atomic_store_n(&glfwd_load_state, 2, __ATOMIC_RELEASE);
		return 1;
	}
	/* Another thread got there first. It is inside a dlopen, which finishes. */
	while (__atomic_load_n(&glfwd_load_state, __ATOMIC_ACQUIRE) != 2)
		sched_yield();
	return 1;
}

/* How much of the dispatcher was actually USED, as opposed to available. The
 * available number is a property of the host's Mesa; these two are a property
 * of the application, and until now nothing here could count them.
 *
 * They are only a call count when the slots were lazy. Eager mode writes the
 * resolved addresses straight into the table, so a call through one of those
 * never reaches the resolver and cannot be counted, so glfwd_was_eager exists so
 * the report says that rather than printing a number that means something else. */
static int glfwd_called_fwd, glfwd_called_absent;
static int glfwd_was_eager;

/*
 * The C half of the resolver. Reached exactly once per entry point per
 * process: on return the caller writes the answer into the slot and every
 * later call goes straight through.
 */
__attribute__((visibility("hidden")))
void *glfwd_resolve_one(int index) {
	void *absent = (void *)(uintptr_t)glfwd_absent;

	/* Cannot happen, because the index is assembled into the trampoline, so if it
	 * ever does, the interesting thing is that it did. */
	if (index < 0 || index >= (int)GLFWD_COUNT) {
		glfwd_log("%s: resolver called with index %d, outside 0..%d; this is a "
		          "corrupt trampoline, returning zero\n",
		          GLFWD_SONAME, index, (int)GLFWD_COUNT - 1);
		return absent;
	}

	if (!glfwd_ensure_target())
		/* Re-entered from inside our own load. Answer THIS call with zero and
		 * leave the slot unresolved, so the next call to the same name gets
		 * the real address. Caching now would freeze a name as absent because
		 * of the order it happened to be called in. */
		return absent;

	void *p = glfwd_addr ? glfwd_addr[index] : NULL;
	int forwarded = p != NULL;
	if (!p)
		p = absent;

	/*
	 * COUNT AND REPORT ONLY IF WE ARE THE ONE THAT PATCHED THE SLOT.
	 *
	 * Two threads can reach this for the SAME index before either has written
	 * the table, an ordinary shape in a threaded renderer, and both would
	 * then count the call and print the line. The counters are labelled "N of
	 * M entry points were CALLED", which is a count of distinct NAMES, so a
	 * double count is not a rounding error, it is the number meaning something
	 * other than what it says. B6's whole value is that this number is
	 * measured rather than estimated, and a measurement that can exceed its
	 * own denominator is worth less than the estimate it replaced.
	 *
	 * The compare-exchange makes the transition itself the thing that is
	 * counted: exactly one thread moves the slot off the resolver, and both
	 * return the same address either way.
	 */
	void *expect = (void *)(uintptr_t)glfwd_resolve_asm;
	if (!__atomic_compare_exchange_n(&glfwd_tab[index], &expect, p, 0,
	                                 __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
		return p;

	if (forwarded) {
		__atomic_fetch_add(&glfwd_called_fwd, 1, __ATOMIC_RELAXED);
		/* One line per entry point the first time it is called. Separate from
		 * CROSS_LIBC_DLOPEN_DEBUG because it is a different question, not "what
		 * did the shim do" but "what does this application USE", and because
		 * the exit summary cannot answer it for the many GL programs that never
		 * exit: a window stays open, the harness sends SIGTERM, and SIGTERM
		 * does not run destructors. This is the only form of the count that
		 * survives a program being killed. */
		if (glfwd_trace())
			glfwd_log("first call: %s\n", glfwd_names[index]);
	} else {
		__atomic_fetch_add(&glfwd_called_absent, 1, __ATOMIC_RELAXED);
		/* B1. THE POINT OF ALL OF THIS. Before this existed an entry point the
		 * host does not implement returned zero and said nothing, which is the
		 * exact failure mode this repository spends the most words warning
		 * about, and the shim had one by construction. One line, at the
		 * first call, naming the entry point. Not fatal: returning zero is
		 * what the application would get natively on this host, where the name
		 * is equally absent. Fatal would be a policy decision about somebody
		 * else's Mesa. */
		if (glfwd_target)
			glfwd_log("ABSENT entry point called: %s -- this host's %s has no "
			          "implementation; returning zero\n",
			          glfwd_names[index], GLFWD_SONAME);
	}
	return p;
}

__attribute__((constructor))
static void glfwd_init(void) {
	/* B4: no dlopen here. The whole constructor is now one optional branch.
	 *
	 * CROSS_LIBC_DLOPEN_GL_EAGER=1 restores the old behaviour, resolving everything
	 * before main(), and exists so the cost of NOT doing that stays a
	 * measurement rather than a memory. It is also the honest way to ask "how
	 * much of this dispatcher could this host stand behind", which is a
	 * question about the host and not about the run. */
	const char *eager = cld_getenv("CROSS_LIBC_DLOPEN_GL_EAGER", NULL);
	if (!(eager && strcmp(eager, "1") == 0)) {
		glfwd_log("%s: %d entry points, none resolved yet -- the host stack "
		          "loads at the first GL call, not here\n",
		          GLFWD_SONAME, (int)GLFWD_COUNT);
		return;
	}
	glfwd_was_eager = 1;
	glfwd_ensure_target();
	for (int i = 0; i < (int)GLFWD_COUNT; i++)
		if (glfwd_addr && glfwd_addr[i])
			glfwd_tab[i] = glfwd_addr[i];
}

__attribute__((destructor))
static void glfwd_report(void) {
	if (!glfwd_debug() && !glfwd_trace())
		return;
	if (__atomic_load_n(&glfwd_load_state, __ATOMIC_ACQUIRE) != 2) {
		glfwd_log("%s: not one entry point was called in this process\n",
		          GLFWD_SONAME);
		return;
	}
	if (glfwd_was_eager) {
		/* Say what was NOT measured rather than print a smaller number under
		 * the same words. Eager patches the resolved slots before main(), so
		 * calls through them never reach the resolver; only the absent ones
		 * still do, and only they can be counted. */
		glfwd_log("%s: EAGER: %d of %d entry points were resolved before "
		          "main(), so the forwarded call count is not measured here. "
		          "%d absent entry point(s) were called\n",
		          GLFWD_SONAME, glfwd_resolved_count, (int)GLFWD_COUNT,
		          glfwd_called_absent);
		return;
	}
	/* The number B6 is about: 3470 forwarded entry points, and how many an
	 * application actually touches. Reported, never thresholded, because it is a
	 * property of the application, and a bar here would be a bar on somebody
	 * else's program. */
	glfwd_log("%s: %d of %d entry points were CALLED (%d forwarded, %d absent) "
	          "out of %d this host could resolve\n",
	          GLFWD_SONAME, glfwd_called_fwd + glfwd_called_absent,
	          (int)GLFWD_COUNT, glfwd_called_fwd, glfwd_called_absent,
	          glfwd_resolved_count);
}
