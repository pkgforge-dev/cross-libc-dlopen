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
gl-fwd-verify:
	@want=$$(sed -n 's/^#define GLFWD_COUNT *//p' $(TBL)); \
	 have=$$(nm -D --defined-only $(SO) | grep -cE ' (T|i) (gl|egl)'); \
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

# Does the aarch64 half still assemble? Cheap, and it catches the syntax errors
# that would otherwise sit unnoticed until someone has the hardware. It is the
# WEAKER of the two checks: `make gl-fwd-qemu-check` below actually runs them.
gl-fwd-asm-check:
	@command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || { \
	   echo "SKIPPED: no aarch64-linux-gnu-gcc. On Debian or Ubuntu:"; \
	   echo "         apt-get install gcc-aarch64-linux-gnu libc6-dev-arm64-cross"; \
	   echo "         (the compiler alone has no headers and fails on dirent.h)"; \
	   exit 0; }
	aarch64-linux-gnu-gcc $(SOFLAGS) -O2 -c \
		-DGLFWD_TABLE='"gl-fwd-gl.h"' gl-fwd.c -o /tmp/gl-fwd-aarch64.o
	@echo "ok: the aarch64 trampolines assemble (see gl-fwd-qemu-check for run)"

# And do they RUN? qemu-user executes an aarch64 binary on an x86_64 kernel in
# userspace, and everything under test (trampoline, resolver, ld.so binding a
# DT_NEEDED to a preloaded object with the same SONAME, dlopen) is userspace.
#
# The emulator is named rather than reached through binfmt_misc: a binfmt
# handler is a kernel registration that outlives the container and changes how
# the machine treats every aarch64 file afterwards. Naming it changes nothing
# outside this process, and needs no privilege.
#
# ⚠ `podman run --platform linux/arm64` is NOT the cheap alternative it looks
# like: pulling a tag for another platform REPLACES the cached image for that
# tag, and the next x86_64 run of that image dies with "Exec format error".
#
# experiments/run.ps1 section P (E76, E76b) is this check with the register and
# absent-path assertions attached; this target is the quick standalone form.
gl-fwd-qemu-check:
	@command -v qemu-aarch64-static >/dev/null 2>&1 && \
	 command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || { \
	   echo "SKIPPED: needs qemu-user-static and gcc-aarch64-linux-gnu"; \
	   echo "         apt-get install qemu-user-static gcc-aarch64-linux-gnu \\"; \
	   echo "                         libc6-dev-arm64-cross"; \
	   exit 0; }
	@t=$$(mktemp -d); \
	 printf 'void t_one(void){}\n' > $$t/tgt.c; \
	 printf '#ifndef GLFWD_SONAME\n#define GLFWD_SONAME "libtgt.so"\n#define GLFWD_COUNT 1\n#endif\nGLFWD_SYM(0, t_one)\n' > $$t/tgt-fwd.h; \
	 printf 'extern void t_one(void);\nint main(void){t_one();return 0;}\n' > $$t/m.c; \
	 cp gl-fwd.c ld-conf.h cld-env.h $$t/; \
	 aarch64-linux-gnu-gcc -shared -fPIC -O2 $$t/tgt.c -o $$t/libtgt.so -Wl,-soname,libtgt.so && \
	 (cd $$t && aarch64-linux-gnu-gcc -shared -fPIC -O2 -DGLFWD_TABLE='"tgt-fwd.h"' \
	     -Wl,-soname,libtgt.so gl-fwd.c -o tgt-fwd.so -ldl) && \
	 aarch64-linux-gnu-gcc -O2 $$t/m.c -o $$t/m $$t/tgt-fwd.so && \
	 qemu-aarch64-static -L /usr/aarch64-linux-gnu \
	     -E LD_PRELOAD=$$t/tgt-fwd.so -E CROSS_LIBC_DLOPEN_GL_HOST_DIR=$$t $$t/m && \
	 echo "ok: the aarch64 trampolines and resolver RAN under qemu-user" || \
	 { echo "FAIL: the aarch64 build ran and did not succeed"; rm -rf $$t; exit 1; }; \
	 rm -rf $$t

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
