#!/bin/sh
# Verify a set of built artefacts and write the manifest beside them.
#
#   scripts/verify-artifacts.sh <artefact-dir> [repo-root]
#
# Standalone on purpose: CI runs it against a directory of downloaded
# artefacts, without a compiler anywhere near it.
#
# THREE PROPERTIES, and each one fails silently if it is wrong rather than
# loudly, which is why they are checked rather than assumed:
#
#   SONAME        a forwarding shim whose SONAME is not the library it
#                 replaces still loads. ld.so simply never binds anything to
#                 it, so it forwards nothing and nothing says why.
#   export count  a shim exporting fewer entry points than its table declares
#                 hands some application `undefined symbol` -- not at load,
#                 but at whichever call the missing one turns out to be.
#   max GLIBC_    an artefact needing a symbol version newer than the floor
#                 loads fine on the machine that built it and fails inside a
#                 bundle whose glibc is older. This is THE floor rule.
set -eu

DIR=${1:?usage: verify-artifacts.sh <artefact-dir> [repo-root]}
REPO=${2:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
SRC=${CLD_SRC:-$REPO/src}
NM=${CLD_NM:-nm}
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
	got_n=$($NM -D --defined-only "$p" 2>/dev/null | grep -cE ' (T|i) (gl|egl)' || true)
	[ "$got_son" = "$want_son" ] || bad "$so SONAME is '$got_son', must be '$want_son'"
	[ "$got_n" = "$want_n" ]     || bad "$so exports $got_n entry points, the table declares $want_n"
	[ "$got_son" = "$want_son" ] && [ "$got_n" = "$want_n" ] &&
		say "$so: SONAME $got_son, $got_n entry points"
done

# ⭐ FATAL: the endbr64 instrumentation, which is what -fcf-protection=full
# actually delivers. A build where the flag was dropped -- by an edit, or by
# the Makefile's CET_CFLAGS failing to resolve on a host whose compiler does
# not answer -dumpmachine the expected way -- produces a shim with none, and
# nothing else here would notice. x86-64 only: CET is an x86 feature and the
# aarch64 shim correctly has no endbr64 at all.
#
# ⚠ REPORTED, NOT FATAL: the .note.gnu.property IBT note, which is absent.
# The reason is measured, and it is not the one this check used to give.
# `-fcf-protection=full` alone emits no note on bullseye (gcc 10.2), bookworm
# (12.2) or trixie (14.2) -- because glibc's crti.o carries no property on any
# of the three, and the linker ANDs that absence across the link.
# ⛔ `-Wl,-z,ibt,-z,shstk` DOES emit one on all three, and the note it emits is
# FALSE: _init and _fini come from crti.o/crtn.o, ld.so reaches them through
# DT_INIT and DT_FINI -- an indirect call -- and neither begins with endbr64.
# Forcing the note would assert a property the object does not have, which is
# worse than not having the note. docs/REPORT.md 9.13 has the full table.
if [ -f "$DIR/gl-fwd.so" ] && [ "$ARCH" = x86_64 ]; then
	nend=$($OBJDUMP -d "$DIR/gl-fwd.so" 2>/dev/null | grep -c endbr64 || true)
	if [ "${nend:-0}" -gt 0 ]; then
		say "gl-fwd.so: $nend endbr64 (the CET instrumentation that IS delivered)"
	else
		bad "gl-fwd.so has no endbr64. -fcf-protection=full did not reach this build."
	fi
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
		n=$($NM -D --defined-only "$DIR/$f" 2>/dev/null | grep -cE ' (T|i) (gl|egl)' || true)
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
