#!/bin/sh
# Turn a verified build directory into release assets.
#
#   sh scripts/package-release.sh <arch> [build-dir] [out-dir]
#
# ⛔ IT VERIFIES, IT DOES NOT RECOMPUTE. Every artefact's sha256 is already in
# build-manifest.json, written by scripts/verify-artifacts.sh at build time.
# This reads that value and CHECKS the file against it. Recomputing would
# produce a number that agrees with the file and says nothing about whether the
# file is the one the verifier passed, and a release whose checksums disagree
# with its own manifest is the defect this ordering exists to prevent.
#
# ⛔ NO NESTED DIRECTORY INSIDE THE ARCHIVES. An extract drops the files where
# the user is standing. Nothing here needs a directory: it is five objects, a
# manifest and a licence, all of which a consumer copies into one place.
#
# ⭐ "Each artefact ships three ways" is read as: loose, or out of the tar, or
# out of the zip. Each of the five is a separate loose asset, and both archives
# carry the whole set. Five one-file archives times two formats would be
# fifteen assets per architecture that nobody wants separately.
set -eu

ARCH=${1:?usage: package-release.sh <arch> [build-dir] [out-dir]}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=${2:-$ROOT/build/$ARCH}
OUT=${3:-$ROOT/dist}

die()  { printf 'package: %s\n' "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

command -v jq  >/dev/null 2>&1 || die "jq is not on PATH"
command -v tar >/dev/null 2>&1 || die "tar is not on PATH"
command -v zip >/dev/null 2>&1 || die "zip is not on PATH"

MAN=$BUILD/build-manifest.json
[ -f "$MAN" ] || die "no manifest at $MAN. Run scripts/build.sh first."

sha_of() {
	if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else die "no sha256sum or shasum, and a release will not be cut without one"
	fi
}

man_arch=$(jq -r '.arch' "$MAN")
[ "$man_arch" = "$ARCH" ] ||
	die "the manifest in $BUILD says arch=$man_arch, and this was asked for $ARCH"

# ⭐ The build variant, taken from the manifest rather than from the directory
# name, so a directory somebody renamed cannot mislabel an asset.
#
#   default    reads APPDIR as well as CROSS_LIBC_DLOPEN_ROOT
#   strictenv  reads only CROSS_LIBC_DLOPEN_ROOT
#
# ⚠ The variant ships as ARCHIVES ONLY, and the default ships loose as well.
# All five objects differ between the two, so the whole set is the unit
# somebody choosing the variant wants; five more loose files per architecture
# would double the asset list to save them one extract.
VARIANT=$(jq -r '.variant // "default"' "$MAN")
case "$VARIANT" in
	default)   BASE=cross-libc-dlopen-$ARCH;         LOOSE=1 ;;
	strictenv) BASE=cross-libc-dlopen-strictenv-$ARCH; LOOSE=0 ;;
	*) die "unknown build variant '$VARIANT' in $MAN" ;;
esac
floor=$(jq -r '.floor_glibc' "$MAN")
[ "$floor" != unknown ] && [ -n "$floor" ] ||
	die "the manifest records no glibc floor. A release states its floor or it is not made."

printf '\n== packaging %s, variant %s (floor glibc %s) ==\n' "$ARCH" "$VARIANT" "$floor"

mkdir -p "$OUT"
STAGE=$(mktemp -d) || die "cannot make a staging directory"
trap 'rm -rf "$STAGE"' EXIT INT TERM

# --------------------------------------- 1. every artefact against its hash --
names=$(jq -r '.artifacts | keys[]' "$MAN")
[ -n "$names" ] || die "the manifest lists no artefacts"

n=0
for f in $names; do
	src=$BUILD/$f
	[ -f "$src" ] || die "$f is in the manifest and not in $BUILD"
	want=$(jq -r --arg f "$f" '.artifacts[$f].sha256' "$MAN")
	got=$(sha_of "$src")
	[ "$want" = "$got" ] ||
		die "$f does not match its manifest entry.
      manifest $want
      file     $got
      The build and the manifest disagree, so neither can be published."
	mx=$(jq -r --arg f "$f" '.artifacts[$f].max_glibc' "$MAN")
	# ⛔ The floor rule, re-asserted at packaging time. verify-artifacts.sh
	# already refused a build that broke it; this refuses to PUBLISH one,
	# because the two run at different times and a manifest can be carried
	# between them.
	if [ "$mx" != none ] && [ "$mx" != null ]; then
		hi=$(printf '%s\n%s\n' "$mx" "$floor" | sort -V | tail -1)
		[ "$hi" = "$floor" ] ||
			die "$f needs GLIBC_$mx, above the floor $floor. It will not be published."
	fi
	say "$f: sha256 matches the manifest, max GLIBC_$mx <= $floor"
	cp "$src" "$STAGE/$f"
	n=$((n + 1))
done

cp "$MAN" "$STAGE/build-manifest.json"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$STAGE/LICENSE"

# ------------------------------------------------ 2. loose, then tar, then zip --
if [ "$LOOSE" = 1 ]; then
	for f in $names; do
		cp "$STAGE/$f" "$OUT/$ARCH-$f"
	done
fi

# ⛔ -C "$STAGE" with bare names, so nothing in the archive has a leading
# directory component. `tar tf` on the result lists plain filenames.
tar -cf "$OUT/$BASE.tar" -C "$STAGE" .
# GNU tar writes a "./" entry for the directory itself; rebuild from the file
# list instead so even that does not appear.
rm -f "$OUT/$BASE.tar"
( cd "$STAGE" && tar -cf "$OUT/$BASE.tar" -- * )
( cd "$STAGE" && zip -q -X "$OUT/$BASE.zip" -- * )

# ---------------------------------------------------- 3. prove that is true --
# ⚠ Asserted rather than assumed: a nested directory is exactly the kind of
# thing that reappears when somebody changes a tar invocation.
if tar -tf "$OUT/$BASE.tar" | grep -q '/'; then
	tar -tf "$OUT/$BASE.tar" | sed 's/^/      /'
	die "the tar has a path separator in it, so it would extract into a directory"
fi
if unzip -Z1 "$OUT/$BASE.zip" 2>/dev/null | grep -q '/'; then
	die "the zip has a path separator in it, so it would extract into a directory"
fi
say "both archives are flat: $(tar -tf "$OUT/$BASE.tar" | tr '\n' ' ')"

# --------------------------------------------------------- 4. the checksums --
# Over every asset, including the archives, which are not in the manifest
# because they did not exist when it was written.
( cd "$OUT" && {
	[ "$LOOSE" = 1 ] && for a in "$ARCH"-*; do
		[ -f "$a" ] || continue
		case "$a" in *.sha256|*.tar|*.zip) continue ;; esac
		printf '%s  %s\n' "$(sha_of "$a")" "$a"
	done
	for a in "$BASE.tar" "$BASE.zip"; do
		[ -f "$a" ] || continue
		printf '%s  %s\n' "$(sha_of "$a")" "$a"
	done
  } ) > "$OUT/$BASE.sha256"

say "$n artefact(s), 2 archive(s), checksums in $BASE.sha256"
printf '  packaged into %s\n' "$OUT"
