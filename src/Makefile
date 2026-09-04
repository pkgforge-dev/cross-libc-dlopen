# Build the cross-libc dlopen fix.
#
# Build on the OLDEST glibc you intend to support, not the newest: the products
# only ever need symbols from that floor, so an old build runs everywhere and a
# new one does not. The measured builds in REPORT.md used debian:bullseye-slim
# (glibc 2.31) and the results run unchanged under the demo AppImage's bundled
# glibc 2.44.
#
#   make                       cross-libc-dlopen.so, gl-fwd.so, egl-fwd.so,
#                              gles-fwd.so, runtime-select
#   make shim FLOOR=... TARGET=... MUSL=...   regenerate forward-shim.c
#   make traps AUDIT_LIBC=...  audit version-compat.c against a libc
#   make gl-syms GLVND=<dir>         regenerate the GL/EGL forwarding tables
#   make gl-syms-check GLVND=<dir>   fail if they no longer match
#   make gles-syms GLES=<dir>        the same, for libGLESv2.so.2
#   make gles-syms-check GLES=<dir>  fail if the GLES table drifted
#   make gl-fwd-asm-check      do the aarch64 trampolines still assemble
#   make gl-fwd-qemu-check     do they RUN, under qemu-user
#   make clean

CC      ?= cc
PYTHON  ?= python3

# -Wno-format-truncation: every snprintf here is deliberately truncating into a
# PATH_MAX buffer, which is the safe behaviour, not a bug to fix.
CFLAGS  ?= -O2 -Wall -Wextra -Wno-format-truncation
SOFLAGS  = -shared -fPIC

# Appended to every compile, for a caller that wants a BUILD VARIANT without
# restating the defaults above and letting the two drift apart.
# `make portable` and `scripts/build.sh --portable` pass -DCLD_STRICT_ENV
# through this. ⚠ It named `--strict-env` until issue #13, an option build.sh
# has never parsed.
EXTRA_CFLAGS ?=

# CET is an x86 feature. On aarch64 gcc, -fcf-protection=full is not a warning
# but a hard error, "not supported for this target", so both aarch64 builds
# failed at the first shim before anything else could be measured.
#
# ⚠ Selected by what the COMPILER TARGETS, not by uname: the aarch64 artefacts
# are CROSS-compiled, so the machine running make is x86-64 while the object
# being produced is not. -dumpmachine is the only one of the two that knows.
#
# ⚠ Asked, not assumed: a toolchain built without CET refuses the flag on x86
# too, and that reaches the compiler as a hard error. Issue #13.
CC_TARGET  := $(shell $(CC) -dumpmachine 2>/dev/null)
CET_OK     := $(shell printf 'int main(void){return 0;}' > .cet-probe.c 2>/dev/null && \
                $(CC) -fcf-protection=full -c .cet-probe.c -o .cet-probe.o >/dev/null 2>&1 && \
                echo yes; rm -f .cet-probe.c .cet-probe.o)
CET_CFLAGS := $(if $(filter x86_64% i386% i686% amd64%,$(CC_TARGET)),$(if $(CET_OK),-fcf-protection=full,),)

ROOT     = ..
FLOOR   ?= $(ROOT)/inventories/appdir.json
TARGET  ?= $(ROOT)/inventories/glibc-2.44.json
# The shipped forward-shim.c was generated WITH a musl inventory. Leaving it out
# drops 33 of 35 definitions and silently disarms the entire musl bridge, so it
# is a default here rather than something the caller has to remember (issue #1).
MUSL    ?= $(ROOT)/inventories/musl-1.2.5.json
# Whichever libc the trap audit runs against. Any glibc will do; the set only
# grows with newer releases, so prefer the newest one you care about.
#
# Found rather than hardcoded: Debian and Ubuntu put it under a triplet
# directory, Arch, Fedora and openSUSE do not, and a default that exists on one
# of those and not the others makes `make traps` a Debian-only command.
AUDIT_LIBC ?= $(firstword $(wildcard \
                /lib/x86_64-linux-gnu/libc.so.6 \
                /usr/lib/x86_64-linux-gnu/libc.so.6 \
                /usr/lib64/libc.so.6 \
                /lib64/libc.so.6 \
                /usr/lib/libc.so.6))

# Where the BUNDLED libglvnd lives. The forwarding tables are read out of it,
# because the shim's one correctness rule is that it exports everything the
# object it replaces exports. Only `make gl-syms*` needs this; an ordinary
# build uses the tables already checked in.
GLVND   ?= $(ROOT)/.tmp/AppDir/lib
# The GLES table comes from an AppDir that BUNDLES GLES, which the
# host-drivers demo does not. Separate knob, separate AppImage.
GLES    ?= $(ROOT)/.tmp/gtk4x/AppDir/lib

all: cross-libc-dlopen.so gl-fwd.so egl-fwd.so gles-fwd.so runtime-select

# The packager's variant, without the build script. docs/building.md says what
# the two flags do and why the CET one is dropped.
portable:
	$(MAKE) EXTRA_CFLAGS='-DCLD_STRICT_ENV $(EXTRA_CFLAGS)' CET_CFLAGS= all

# The preload carries the shim: it is already in the global lookup scope, so
# its exports satisfy undefined symbols in anything dlopen'd later (E2, E5).
cross-libc-dlopen.so: cross-libc-dlopen.c forward-shim.c version-compat.c cld-env.h
	@# $(filter %.c,$^), not $^: cld-env.h is a prerequisite so a change to it
	@# rebuilds this, but handing a .h to gcc makes it precompile the header
	@# and drop a .gch beside the source instead of compiling anything.
	$(CC) $(SOFLAGS) $(CFLAGS) $(EXTRA_CFLAGS) $(filter %.c,$^) -o $@ -ldl
	@# 5.1's build check: exactly one exported definition, no accidental dupes.
	@# atexit comes from the musl bridge, pthread_cond_init and realpath from
	@# the version-trap forwarders. A collision between the two files, or a
	@# generator that emitted a name twice, shows up here as 2.
	@for s in atexit pthread_cond_init realpath; do \
	   n=$$(nm -D --defined-only $@ 2>/dev/null | grep -cw $$s); \
	   if [ "$$n" != "1" ]; then echo "FAIL: $$s exported $$n times, want 1"; exit 1; fi; \
	 done; \
	 echo "ok: atexit, pthread_cond_init, realpath each exported exactly once"

# The OpenGL and EGL forwarding shims. Each is built with the SONAME of the
# bundled dispatcher it replaces, so preloading it makes ld.so bind an
# application's DT_NEEDED to it instead.
#
# $(CET_CFLAGS) puts an endbr64 at every indirect-branch target on x86-64. It
# does NOT produce an IBT property note, and this comment used to say it did.
# Measured on bullseye, bookworm and trixie: the note is absent because glibc's
# crti.o carries no property, and the linker ANDs that absence across the link.
# ⚠ -Wl,-z,ibt DOES emit a note, and the note is FALSE: _init and _fini come
# from crti.o/crtn.o, ld.so reaches them through DT_INIT/DT_FINI, an indirect
# call, and neither begins with endbr64. docs/report/09-the-second-boundary.md
# 9.13 has the table.
gl-fwd.so: gl-fwd.c gl-fwd-gl.h ld-conf.h cld-env.h
	$(CC) $(SOFLAGS) $(CFLAGS) $(CET_CFLAGS) $(EXTRA_CFLAGS) \
		-DGLFWD_TABLE='"gl-fwd-gl.h"' -DGLFWD_TAG='"gl-fwd.so"' \
		-Wl,-soname,libGL.so.1 gl-fwd.c -o $@ -ldl
	@$(MAKE) --no-print-directory gl-fwd-verify SO=$@ TBL=gl-fwd-gl.h

# EGL's dispatcher finds its vendor through a JSON directory rather than a
# libGLX_*.so.0, so the marker differs; everything else is the same object.
egl-fwd.so: gl-fwd.c gl-fwd-egl.h ld-conf.h cld-env.h
	$(CC) $(SOFLAGS) $(CFLAGS) $(CET_CFLAGS) $(EXTRA_CFLAGS) \
		-DGLFWD_TABLE='"gl-fwd-egl.h"' -DGLFWD_TAG='"egl-fwd.so"' \
		-DGLFWD_VENDOR_PREFIX='"libEGL_"' \
		-DGLFWD_VENDOR_DIR='"/usr/share/glvnd/egl_vendor.d"' \
		-DGLFWD_GETPROC='"eglGetProcAddress"' \
		-Wl,-soname,libEGL.so.1 gl-fwd.c -o $@ -ldl
	@$(MAKE) --no-print-directory gl-fwd-verify SO=$@ TBL=gl-fwd-egl.h

# A shim that exports fewer entry points than its table has is a shim that will
# hand some application `undefined symbol`, and the table is 3470 lines long, so
# the count is checked rather than eyeballed. The SONAME is checked too: without
# it the object is inert: it loads, forwards nothing, and nothing says why.
#
# readelf, not nm: an nm built without PowerPC support reads an ELFv1 .opd
# function as data (D) and the count then refuses a correct ppc64 build.
# Measured: host nm 2.46 counts 0 for the same object cross nm counts 3470
# for. readelf's FUNC/GLOBAL/DEFAULT form counts 3470 on both.
gl-fwd-verify:
	@want=$$(sed -n 's/^#define GLFWD_COUNT *//p' $(TBL)); \
	 have=$$(readelf --dyn-syms -W $(SO) | grep -cE ' +FUNC +GLOBAL +DEFAULT +[0-9]+ +(gl|egl)'); \
	 son=$$(objdump -p $(SO) | sed -n 's/^ *SONAME *//p'); \
	 wson=$$(sed -n 's/^#define GLFWD_SONAME  *"//p' $(TBL) | tr -d '"'); \
	 if [ "$$have" != "$$want" ]; then \
	   echo "FAIL: $(SO) exports $$have entry points, the table says $$want"; exit 1; fi; \
	 if [ "$$son" != "$$wson" ]; then \
	   echo "FAIL: $(SO) soname is '$$son', want '$$wson'"; exit 1; fi; \
	 echo "ok: $(SO) is $$son with all $$have entry points"

# GLES is the same shape a third time. libGLESv2.so.2 is a glvnd dispatcher
# like libGL.so.1 and libEGL.so.1, it finds its implementation the way EGL does
# (a JSON file under /usr/share/glvnd/egl_vendor.d, because a GLES context
# comes from EGL), and on a classic-Mesa host there is no such file, so it has
# nothing to dispatch to and every GLES entry point is a silent zero.
#
# The table is read out of the libGLESv2.so.2 bundled by the gtk4 demo AppImage
# (358 entry points). The demo AppDir the rest of this suite uses bundles no
# GLES at all, which is why this shim did not exist until an AppDir that does
# turned up, because the generator's one rule is that the list comes out of the object
# being replaced, and there was no object.
gles-fwd.so: gl-fwd.c gl-fwd-gles2.h ld-conf.h cld-env.h
	$(CC) $(SOFLAGS) $(CFLAGS) $(CET_CFLAGS) $(EXTRA_CFLAGS) \
		-DGLFWD_TABLE='"gl-fwd-gles2.h"' -DGLFWD_TAG='"gles-fwd.so"' \
		-DGLFWD_VENDOR_PREFIX='"libEGL_"' \
		-DGLFWD_VENDOR_DIR='"/usr/share/glvnd/egl_vendor.d"' \
		-DGLFWD_GETPROC='"eglGetProcAddress"' \
		-DGLFWD_ALT_SONAME='"libEGL.so.1"' \
		-Wl,-soname,libGLESv2.so.2 gl-fwd.c -o $@ -ldl
	@$(MAKE) --no-print-directory gl-fwd-verify SO=$@ TBL=gl-fwd-gles2.h

runtime-select: runtime-select.c ld-conf.h cld-env.h
	$(CC) $(CFLAGS) $(EXTRA_CFLAGS) $< -o $@ -ldl

# Regenerate the shim for a different bundled glibc. This is 5.2 step 4: the
# treadmill becomes a build step instead of a per-bug-report patch.
shim:
	$(PYTHON) $(ROOT)/tools/gen_forward_shim.py \
		--floor $(FLOOR) --target $(TARGET) --musl $(MUSL) \
		--out forward-shim.c --manifest forward-shim-manifest.json

# Read the forwarding tables back out of the bundled libglvnd. Needed only when
# the bundled libglvnd changes; the check target is what makes a silent drift
# impossible, and experiments/40-appimage.sh runs it against the real AppDir.
gl-syms:
	$(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLVND)/libGL.so.1 \
		--prefix gl --soname libGL.so.1 --out gl-fwd-gl.h
	$(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLVND)/libEGL.so.1 \
		--prefix egl --prefix EGL --soname libEGL.so.1 --out gl-fwd-egl.h

gl-syms-check:
	$(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLVND)/libGL.so.1 \
		--prefix gl --soname libGL.so.1 --check gl-fwd-gl.h
	$(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLVND)/libEGL.so.1 \
		--prefix egl --prefix EGL --soname libEGL.so.1 --check gl-fwd-egl.h

# GLES gets its own pair, because its table is read out of a DIFFERENT AppImage
# (the host-drivers demo bundles no GLES at all) and a missing one must not
# fail the GL/EGL check, which has nothing to do with it.
gles-syms:
	$(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLES)/libGLESv2.so.2 \
		--prefix gl --soname libGLESv2.so.2 --out gl-fwd-gles2.h

# ⚠ One shell, not two. Every LINE of a recipe is its own shell, so a guard
# that ends in `exit 0` on line one does not stop line two from running: this
# target skipped and then failed anyway, for one revision.
gles-syms-check:
	@if [ ! -f "$(GLES)/libGLESv2.so.2" ]; then \
	   echo "SKIPPED: no $(GLES)/libGLESv2.so.2 to check against."; \
	   echo "         experiments/appimage.ps1 extracts one into .tmp/gtk4x;"; \
	   echo "         or pass GLES=<dir> naming an AppDir lib/ that bundles it."; \
	 else \
	   $(PYTHON) $(ROOT)/tools/gen_gl_fwd.py $(GLES)/libGLESv2.so.2 \
	       --prefix gl --soname libGLESv2.so.2 --check gl-fwd-gles2.h; \
	 fi

# The architectures src/gl-fwd.c carries hand-written trampolines for, besides
# the host's own. Each maps to a Debian cross toolchain and a qemu-user binary;
# a machine with none of them is not weaker, it only SKIPS these checks by name.
GLFWD_CROSS = aarch64 riscv64 ppc64 ppc64le loongarch64

# Do the cross halves still assemble? Cheap, and it catches the syntax errors
# that would otherwise sit unnoticed until someone has the hardware. It is the
# WEAKER of the two checks: `make gl-fwd-qemu-check` below actually runs them.
# The apt names come from Debian; bullseye carries all of them except
# loongarch64, which needs trixie (gcc-14) because the port postdates gcc-10.
gl-fwd-asm-check:
	@rc=0; \
	for a in $(GLFWD_CROSS); do \
	   case $$a in \
	     aarch64)     t=aarch64-linux-gnu;     pk=libc6-dev-arm64-cross ;; \
	     riscv64)     t=riscv64-linux-gnu;     pk=libc6-dev-riscv64-cross ;; \
	     ppc64)       t=powerpc64-linux-gnu;   pk=libc6-dev-ppc64-cross ;; \
	     ppc64le)     t=powerpc64le-linux-gnu; pk=libc6-dev-ppc64el-cross ;; \
	     loongarch64) t=loongarch64-linux-gnu; pk=libc6-dev-loong64-cross ;; \
	   esac; \
	   if command -v $$t-gcc >/dev/null 2>&1; then \
	     if $$t-gcc $(SOFLAGS) -O2 -c -DGLFWD_TABLE='"gl-fwd-gl.h"' \
	          gl-fwd.c -o /tmp/gl-fwd-$$a.o 2>/tmp/gl-fwd-$$a.log; then \
	       echo "ok: the $$a trampolines assemble"; \
	     else \
	       echo "FAIL: the $$a trampolines do not assemble:"; \
	       sed 's/^/  | /' /tmp/gl-fwd-$$a.log; rc=1; \
	     fi; \
	   else \
	     echo "SKIPPED: no $$t-gcc for $$a. On Debian or Ubuntu:"; \
	     echo "         apt-get install gcc-$$t $$pk"; \
	     echo "         (the compiler alone has no headers and fails on dirent.h)"; \
	   fi; \
	 done; exit $$rc

# And do they RUN? qemu-user executes the target binary on this kernel in
# userspace, and everything under test is userspace: the trampoline, the
# register-saving resolver, ld.so binding a DT_NEEDED to a preloaded object
# with the same SONAME, dlopen, and, on ppc64, the ELFv1 .opd descriptor hop
# through the real ld64.so.1. The vehicle passes one argument of every
# register class through a trampoline, calls twice so the patched slot is
# taken too, checks a double return value, and calls a name the target does
# not define so the absent stub is exercised; m.c verifies each value and
# prints "all passed" only when every one held.
#
# The emulator is named rather than reached through binfmt_misc: a binfmt
# handler is a kernel registration that outlives the container and changes how
# the machine treats every target-arch file afterwards. Naming it changes
# nothing outside this process, and needs no privilege.
#
# loongarch64 needs a qemu new enough for the sysroot's glibc: measured,
# qemu 7.2 faults on trixie's glibc 2.42 where 10.0 runs it; anything between
# is unmeasured. The -static name is tried first because that is what
# qemu-user-static ships; trixie also ships a plain qemu-loongarch64 that
# is statically linked too.
#
# experiments/run.ps1 section P (E76, E76b) is the aarch64 row of this check
# with the register and absent-path assertions attached; this target is the
# form that covers every architecture a developer can cross-compile.
gl-fwd-qemu-check:
	@rc=0; \
	for a in $(GLFWD_CROSS); do \
	   case $$a in \
	     aarch64)     t=aarch64-linux-gnu ;; \
	     riscv64)     t=riscv64-linux-gnu ;; \
	     ppc64)       t=powerpc64-linux-gnu ;; \
	     ppc64le)     t=powerpc64le-linux-gnu ;; \
	     loongarch64) t=loongarch64-linux-gnu ;; \
	   esac; \
	   q=''; for cand in qemu-$$a-static qemu-$$a; do \
	     command -v $$cand >/dev/null 2>&1 && { q=$$cand; break; }; \
	   done; \
	   if ! command -v $$t-gcc >/dev/null 2>&1 || [ -z "$$q" ]; then \
	     echo "SKIPPED: $$a needs $$t-gcc and a qemu-user binary for $$a"; \
	     continue; \
	   fi; \
	   d=$$(mktemp -d); \
	   printf 'long t_args(int a, long b, double c, const char *d) {\n	if (a != 7)            return 1;\n	if (b != 0x123456789L) return 2;\n	if (c != 2.718281828)  return 3;\n	if (!d || d[0] != 120 || d[1] != 121) return 4;\n	return a + b + (long)c + d[2];\n}\ndouble t_fret(int a) { return a * 1.5; }\nvoid t_one(void) {}\n' > $$d/tgt.c; \
	   printf '#ifndef GLFWD_SONAME\n#define GLFWD_SONAME "libtgt.so"\n#define GLFWD_COUNT 5\n#endif\nGLFWD_SYM(0, t_args)\nGLFWD_SYM(1, t_fret)\nGLFWD_SYM(2, t_one)\nGLFWD_SYM(3, t_absent)\nGLFWD_SYM(4, t_absent_f)\n' > $$d/tgt-fwd.h; \
	   printf '#include <stdio.h>\nextern long t_args(int, long, double, const char *);\nextern double t_fret(int);\nextern void t_one(void);\nextern long t_absent(int);\nextern double t_absent_f(int);\nint main(void) {\n\tconst char *s = "xyz";\n\tlong r1 = t_args(7, 0x123456789L, 2.718281828, s);\n\tlong r2 = t_args(7, 0x123456789L, 2.718281828, s);\n\tif (r1 != r2) return 1;\n\tdouble d1 = t_fret(4), d2 = t_fret(4);\n\tif (d1 != 6.0 || d2 != 6.0) return 2;\n\tt_one();\n\tif (t_absent(9) != 0) return 3;\n\tif (t_absent_f(9) != 0.0) return 4;\n\tputs("all passed");\n\treturn 0;\n}\n' > $$d/m.c; \
	   cp gl-fwd.c ld-conf.h cld-env.h $$d/; \
	   if $$t-gcc -shared -fPIC -O2 $$d/tgt.c -o $$d/libtgt.so -Wl,-soname,libtgt.so -lm \
	      && (cd $$d && $$t-gcc -shared -fPIC -O2 -DGLFWD_TABLE='"tgt-fwd.h"' \
	          -Wl,-soname,libtgt.so gl-fwd.c -o tgt-fwd.so -ldl) \
	      && $$t-gcc -O2 $$d/m.c -o $$d/m $$d/tgt-fwd.so -lm \
	      && $$q -L /usr/$$t -E LD_PRELOAD=$$d/tgt-fwd.so \
	           -E CROSS_LIBC_DLOPEN_GL_HOST_DIR=$$d $$d/m | grep -q 'all passed'; then \
	     echo "ok: the $$a trampolines and resolver RAN under qemu-user ($$q)"; \
	   else \
	     echo "FAIL: the $$a build ran and did not succeed"; \
	     if [ "$$a" = loongarch64 ]; then \
	       echo "      $$q is $$($$q --version | head -1); measured: 7.2 faults on a"; \
	       echo "      current loong64 glibc, 10.0 runs it, between is unmeasured"; \
	     fi; \
	     rc=1; \
	   fi; \
	   rm -rf $$d; \
	 done; exit $$rc

# Does version-compat.c still cover every multi-version trap this libc has?
# Run it against the NEWEST glibc you care about: the set only grows.
traps:
	@if [ -z "$(AUDIT_LIBC)" ]; then \
	   echo "FAIL: no libc.so.6 found in any of the usual places."; \
	   echo "      Pass one: make traps AUDIT_LIBC=/path/to/libc.so.6"; \
	   exit 1; \
	 fi
	$(PYTHON) $(ROOT)/tools/version_traps.py $(AUDIT_LIBC) --check version-compat.c

clean:
	rm -f cross-libc-dlopen.so gl-fwd.so egl-fwd.so gles-fwd.so runtime-select

.PHONY: all shim traps clean gl-syms gl-syms-check gles-syms gles-syms-check \
        gl-fwd-verify gl-fwd-asm-check gl-fwd-qemu-check
