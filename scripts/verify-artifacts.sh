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

# gl-fwd.so must carry the IBT property note: the trampolines start with
# endbr64, and without the note a CET-enforcing host turns indirect-branch
# tracking off for the whole process. That is a mitigation lost in silence.
#
# ⚠ REPORTED, NOT FATAL, and the reason is measured rather than a shrug: no
# Debian gcc emits the note. Tried on bullseye (gcc 10.2), bookworm (12.2) and
# trixie (14.2), with -fcf-protection=full, with -Wl,-z,ibt,-z,shstk, and on a
# one-function file with no project code in it. None produced a
# .note.gnu.property section. Failing the build on it would block every build
# over a toolchain property no source change here can reach, so it prints on
# every build instead and TODO/infrastructure.md T-17 carries the work.
if [ -f "$DIR/gl-fwd.so" ] && [ "$ARCH" = x86_64 ]; then
	if command -v readelf >/dev/null 2>&1 &&
	   readelf -n "$DIR/gl-fwd.so" 2>/dev/null | grep -qi 'propert'; then
		say "gl-fwd.so: IBT property note present"
	else
		say "gl-fwd.so: NO IBT property note (known: no Debian gcc emits one; T-17)"
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
