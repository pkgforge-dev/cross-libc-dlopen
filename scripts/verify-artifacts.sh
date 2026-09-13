#!/bin/sh
# Verify a set of built artefacts and write the manifest beside them.
#
#   scripts/verify-artifacts.sh <artefact-dir> [repo-root]
#
# Standalone on purpose: CI runs it against a directory of downloaded
# artefacts, without a compiler anywhere near it.
#
# FOUR PROPERTIES, and each one fails silently if it is wrong rather than
# loudly, which is why they are checked rather than assumed:
#
#   SONAME        a forwarding shim whose SONAME is not the library it
#                 replaces still loads. ld.so simply never binds anything to
#                 it, so it forwards nothing and nothing says why.
#   export count  a shim exporting fewer entry points than its table declares
#                 hands some application `undefined symbol`, not at load,
#                 but at whichever call the missing one turns out to be.
#   max GLIBC_    an artefact needing a symbol version newer than the floor
#                 loads fine on the machine that built it and fails inside a
#                 bundle whose glibc is older. This is THE floor rule.
#   name collision an unversioned definition in a preload wins the lookup for
#                 a versioned reference, so any exported name the target's own
#                 libc family also exports silently replaces that
#                 implementation for the WHOLE process, the loader's own
#                 included. Measured as issue #37, __stack_chk_guard.
set -eu

DIR=${1:?usage: verify-artifacts.sh <artefact-dir> [repo-root]}
REPO=${2:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
SRC=${CLD_SRC:-$REPO/src}
OBJDUMP=${CLD_OBJDUMP:-objdump}
ARCH=${CLD_ARCH:-$(uname -m)}
FLOOR=${CLD_FLOOR_GLIBC:-unknown}

fail=0
say()  { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; fail=$((fail + 1)); }

# The highest GLIBC_x.y this object requires. sort -V so 2.9 does not beat 2.31.
max_glibc() {
	$OBJDUMP -T "$1" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' |
		sed 's/GLIBC_//' | sort -uV | tail -1
}

soname_of() { $OBJDUMP -p "$1" 2>/dev/null | sed -n 's/^ *SONAME *//p'; }

# What the table says this shim must be, and how many entry points it has.
table_soname() { sed -n 's/^#define GLFWD_SONAME  *"//p' "$1" | tr -d '"'; }
table_count()  { sed -n 's/^#define GLFWD_COUNT *//p' "$1"; }

sha() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else printf 'unavailable'; fi
}

printf '\n-- verifying %s (%s, floor glibc %s) --\n' "$DIR" "$ARCH" "$FLOOR"

# ------------------------------------------------------------ the two rules --
for f in cross-libc-dlopen.so gl-fwd.so egl-fwd.so gles-fwd.so runtime-select; do
	p=$DIR/$f
	[ -f "$p" ] || { bad "$f is missing"; continue; }
	mx=$(max_glibc "$p")
	[ -n "$mx" ] || mx=none
	if [ "$mx" != none ] && [ "$FLOOR" != unknown ]; then
		hi=$(printf '%s\n%s\n' "$mx" "$FLOOR" | sort -V | tail -1)
		if [ "$hi" != "$FLOOR" ]; then
			bad "$f needs GLIBC_$mx, above the floor $FLOOR. It will fail to load under an older bundled glibc."
			continue
		fi
	fi
	say "$f: max GLIBC_$mx (floor $FLOOR)"
done

# ------------------------------------------- SONAME and export count, shims --
for pair in 'gl-fwd.so gl-fwd-gl.h' 'egl-fwd.so gl-fwd-egl.h' 'gles-fwd.so gl-fwd-gles2.h'; do
	so=${pair% *}; tbl=${pair#* }
	p=$DIR/$so; t=$SRC/$tbl
	[ -f "$p" ] || continue
	if [ ! -f "$t" ]; then say "$so: no $tbl to check against, SONAME/count unverified"; continue; fi
	want_son=$(table_soname "$t"); got_son=$(soname_of "$p")
	want_n=$(table_count "$t")
	# readelf rather than nm: an nm built without PowerPC support reads an
	# ELFv1 .opd function as data (D), and the count then refused a correct
	# build of the ppc64 target this project no longer produces. Measured
	# then: host nm counted 0 where cross nm counted 3470. The readelf
	# FUNC/GLOBAL/DEFAULT form counts 3470 on every target and is kept.
	got_n=$(readelf --dyn-syms -W "$p" 2>/dev/null | grep -cE ' +FUNC +GLOBAL +DEFAULT +[0-9]+ +(gl|egl)' || true)
	[ "$got_son" = "$want_son" ] || bad "$so SONAME is '$got_son', must be '$want_son'"
	[ "$got_n" = "$want_n" ]     || bad "$so exports $got_n entry points, the table declares $want_n"
	[ "$got_son" = "$want_son" ] && [ "$got_n" = "$want_n" ] &&
		say "$so: SONAME $got_son, $got_n entry points"
done

# ------------------------------------------ the preload versus the target --
# The FOURTH property, and it is about names rather than versions: the
# preload exports nothing the target's own libc family exports, beyond the
# two audited interpositions. An unversioned definition in a preload wins
# the lookup for a versioned reference, so any other shared name silently
# replaces the target's implementation for the WHOLE process. The
# __stack_chk_guard case is the measured one: on aarch64, riscv64 and
# loongarch64 the dynamic loader exports the name as the process-wide stack
# canary, the shim defined it as a function stub, chromium's GPU process
# died with SIGSEGV under the preload with the feature switch off, and
# x86-64 and ppc64le were untouched because their loaders never export the
# name (issue #37). The generator excludes it per architecture; this check
# re-measures the built object so an architecture added later fails here
# rather than in somebody's browser.
#
# The audited interpositions, exempt by name:
#   dlopen                      the point of the project
#   version-compat.c's forwarders deliberate, and each one forwards to the
#                               default definition it displaced
defined_names() {
	# "$@" and not "$1": the target is a LIST (libc plus its loader), and a
	# function that read only the first member once measured a whole gate
	# against libc.so.6 alone and reported the loader's own canary absent.
	readelf --dyn-syms -W "$@" 2>/dev/null |
	# PPC64 ELFv2 readelf prints a st_other annotation, [<localentry>: 8],
	# between the visibility and the index, which shifts the name out of
	# column 8 and once made every name parse as the two characters 8].
	# Stripped before the columns are read. Measured on the bullseye cross
	# binutils; newer binutils on x86-64 print no such column for the same
	# file, which is why a local rehearsal of this gate saw nothing.
	sed 's/\[<localentry>:[^]]*\]//' | \
		awk '$7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") &&
		     $6 == "DEFAULT" { n = $8; sub(/@.*/, "", n); print n }' |
		sort -u
}

# The forwarder set, read out of the source that defines it so the two
# cannot drift apart silently.
forwarder_names() {
	sed -n 's/^VC_VISIBLE .*[ *]\([A-Za-z_][A-Za-z0-9_]*\)(.*/\1/p' \
		"$SRC/version-compat.c" 2>/dev/null | sort -u
}

if [ -f "$DIR/cross-libc-dlopen.so" ]; then
	case "$ARCH" in
		x86_64)      triplet=x86_64-linux-gnu ;;
		i386)        triplet=i386-linux-gnu ;;
		aarch64)     triplet=aarch64-linux-gnu ;;
		riscv64)     triplet=riscv64-linux-gnu ;;
		ppc64le)     triplet=powerpc64le-linux-gnu ;;
		loongarch64) triplet=loongarch64-linux-gnu ;;
		*) triplet='' ;;
	esac
	# Where the target's own libc family lives. The build container carries
	# it in the cross sysroot, /usr/<triplet>/lib, and a native build carries
	# it in this machine's own directories. CLD_SYSROOT names a sysroot root
	# explicitly for a verification run outside a build, which is how the
	# gate's own refusal below was proven on a machine of the other
	# architecture.
	SYSROOT=${CLD_SYSROOT:-}

	targets=''
	if [ -n "$triplet" ]; then
		if [ -n "$SYSROOT" ]; then
			for d in "$SYSROOT/lib" "$SYSROOT/lib64"; do
				[ -d "$d" ] || continue
				for f in "$d"/libc.so.6 "$d"/ld-linux*.so* \
				         "$d"/ld64.so* "$d"/ld-[0-9]*.so; do
					[ -f "$f" ] || continue
					targets="$targets $f"
				done
			done
		else
		for d in "/usr/$triplet/lib" "/usr/$triplet/lib64" \
		         "/lib/$triplet" "/usr/lib/$triplet"; do
			[ -d "$d" ] || continue
			for f in "$d"/libc.so.6 "$d"/ld-linux*.so* \
			         "$d"/ld64.so* "$d"/ld-[0-9]*.so; do
				[ -f "$f" ] || continue
				targets="$targets $f"
			done
		done
		# The triplet-less directories only carry THIS machine's libc, so
		# they are consulted only when the target is the machine itself: a
		# cross build on an x86-64 host would otherwise check its own
		# libc.so.6 against an aarch64 artefact and report the wrong answer.
		if [ "$(uname -m)" = "$ARCH" ]; then
			for d in /lib/$triplet /usr/lib/$triplet /lib64 /usr/lib64 /lib /usr/lib; do
				[ -d "$d" ] || continue
				for f in "$d"/libc.so.6 "$d"/ld-linux*.so* \
				         "$d"/ld64.so* "$d"/ld-[0-9]*.so; do
					[ -f "$f" ] || continue
					targets="$targets $f"
				done
			done
		fi
		fi
	fi
	if [ -z "$(printf '%s' "$targets" | tr -d ' ')" ]; then
		say "cross-libc-dlopen.so: no $ARCH libc family found to check"
		say "exports against, name collisions unverified"
	else
		defs=$(defined_names "$DIR/cross-libc-dlopen.so")
		# shellcheck disable=SC2086
		theirs=$(defined_names $targets)
		{
			printf '%s\n' dlopen cross_libc_dlopen_init_now
			forwarder_names
		} | sort -u > "$DIR/.cld-exempt.$$"
		hits=$(printf '%s\n%s\n' "$defs" "$theirs" | sort | uniq -d |
			grep -vxF -f "$DIR/.cld-exempt.$$" || true)
		rm -f "$DIR/.cld-exempt.$$"
		if [ -n "$hits" ]; then
			bad "cross-libc-dlopen.so exports names the target libc family also
      exports. A preload definition wins every lookup for each of them,
      the loader's own included. Issue #37. The shared names, verbatim:"
			# IFS= read, not a for over the unquoted variable: a name with a
			# space in it once printed as its own last word and named nothing.
			printf '%s\n' "$hits" | while IFS= read -r h; do
				printf '        %s\n' "$h"
				readelf --dyn-syms -W "$DIR/cross-libc-dlopen.so" 2>/dev/null |
					grep -F " $h" | sed 's/^/   so: /'
			done
		else
			say "cross-libc-dlopen.so: no name reexported from the target libc family"
		fi
	fi
fi

# ⭐ The endbr64 count, REPORTED rather than asserted. The trampolines spell
# their endbr64 as literal bytes in gl-fwd.c so the floor's assembler cannot
# be too old for them, and the build asks for no CET flag, so the count here
# should be the trampolines' own and nothing more. E101 in
# experiments/30-run-tests.sh is the case that keeps that true: the default
# recipe must produce strictly fewer endbr64 than the same recipe with the
# flag asked for. x86-64 only: CET is an x86 feature and the shims of every
# other architecture correctly have no endbr64 at all.
#
# ⚠ REPORTED, NOT ASSERTED: the .note.gnu.property IBT note, which is absent.
# The reason is measured. `-fcf-protection=full` emits no note on bullseye
# (gcc 10.2), bookworm (12.2) or trixie (14.2), because glibc's crti.o carries
# no property on any of the three, and the linker ANDs that absence across the
# link. ⛔ `-Wl,-z,ibt,-z,shstk` DOES emit one on all three, and the note it
# emits is FALSE: _init and _fini come from crti.o/crtn.o, ld.so reaches them
# through DT_INIT and DT_FINI, an indirect call, and neither begins with
# endbr64. Forcing the note would assert a property the object does not have,
# which is worse than not having the note.
# docs/report/09-the-second-boundary.md 9.13 has the full table.
if [ -f "$DIR/gl-fwd.so" ] && [ "$ARCH" = x86_64 ]; then
	nend=$($OBJDUMP -d "$DIR/gl-fwd.so" 2>/dev/null | grep -c endbr64 || true)
	say "gl-fwd.so: $nend endbr64"
	# ⛔ REPORTED, NOT ASSERTED, and this comment is the reason.
	#
	# An earlier version of this check refused a build with no endbr64, on the
	# grounds that endbr64 is what -fcf-protection=full actually delivers.
	# ⚠ THAT CHECK COULD NEVER HAVE FAILED. Measured: the trampolines carry
	# 3472 of their own, spelled as literal bytes no compiler flag removes,
	# and the flag arm added six more for 3478. So a count over zero says
	# nothing about whether the flag arrived, and a guard that cannot fail is
	# worse than no guard. The number is printed, the manifest records the
	# variant, and E101 now asserts the count the default build owes.
	if command -v readelf >/dev/null 2>&1 &&
	   readelf -n "$DIR/gl-fwd.so" 2>/dev/null | grep -qi 'propert'; then
		say "gl-fwd.so: IBT property note present"
	else
		say "gl-fwd.so: no IBT property note (measured: glibc's crti.o carries none; T-17)"
	fi
fi

# ------------------------------------------------------------- the manifest --
# src/forward-shim-manifest.json is the existing precedent for the shape.
man=$DIR/build-manifest.json
{
	printf '{\n'
	printf '  "schema": "cross-libc-dlopen/build-manifest/1",\n'
	printf '  "arch": "%s",\n' "$ARCH"
	# Which build variant this is. "default" reads APPDIR as well as
	# CROSS_LIBC_DLOPEN_ROOT; "strictenv" reads only the latter. A consumer
	# holding an object has no other way to tell them apart.
	printf '  "variant": "%s",\n' "${CLD_VARIANT:-default}"
	printf '  "floor_glibc": "%s",\n' "$FLOOR"
	printf '  "compiler": "%s",\n' "$(${CLD_CC:-cc} --version 2>/dev/null | head -1 | sed 's/"/\\"/g')"
	printf '  "sources": {\n'
	first=1
	for s in cross-libc-dlopen.c gl-fwd.c runtime-select.c forward-shim.c version-compat.c \
	         cld-env.h cld-symver.h ld-conf.h gl-fwd-gl.h gl-fwd-egl.h gl-fwd-gles2.h; do
		[ -f "$SRC/$s" ] || continue
		[ $first = 1 ] || printf ',\n'; first=0
		printf '    "%s": "%s"' "$s" "$(sha "$SRC/$s")"
	done
	printf '\n  },\n'
	printf '  "artifacts": {\n'
	first=1
	for f in cross-libc-dlopen.so gl-fwd.so egl-fwd.so gles-fwd.so runtime-select; do
		[ -f "$DIR/$f" ] || continue
		[ $first = 1 ] || printf ',\n'; first=0
		mx=$(max_glibc "$DIR/$f"); [ -n "$mx" ] || mx=none
		son=$(soname_of "$DIR/$f"); [ -n "$son" ] || son=""
		n=$(readelf --dyn-syms -W "$DIR/$f" 2>/dev/null | grep -cE ' +FUNC +GLOBAL +DEFAULT +[0-9]+ +(gl|egl)' || true)
		printf '    "%s": { "sha256": "%s", "max_glibc": "%s", "soname": "%s", "entry_points": %s }' \
			"$f" "$(sha "$DIR/$f")" "$mx" "$son" "${n:-0}"
	done
	printf '\n  }\n}\n'
} > "$man"
say "manifest: $man"

if [ "$fail" -gt 0 ]; then
	printf '\n  %d artefact check(s) failed. Refusing to call this a build.\n' "$fail"
	exit 1
fi
printf '\n  all artefact checks passed\n'
