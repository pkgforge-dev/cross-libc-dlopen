#!/bin/sh
# Generate a release body. ⛔ No part of this is written by hand at release
# time, and that is the point: a body somebody types is a body that disagrees
# with the artefacts within one release.
#
#   sh scripts/release-notes.sh <tag> [dist-dir] [build-root]
#
# ⛔ EVERY NUMBER COMES OUT OF build-manifest.json. scripts/verify-artifacts.sh
# wrote it at build time, from the objects themselves, and it already carries
# the sha256, the maximum GLIBC_ version, the SONAME and the entry-point count
# of every artefact. Recomputing any of that here would let the release and the
# manifest disagree, and the manifest is the one with a check behind it.
#
# The only values computed here are the archive checksums, because the archives
# did not exist when the manifest was written. They are marked as such.
#
# Writes markdown to stdout.
set -eu

TAG=${1:?usage: release-notes.sh <tag> [dist-dir] [build-root]}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST=${2:-$ROOT/dist}
BUILDS=${3:-$ROOT/build}

command -v jq >/dev/null 2>&1 || { echo "release-notes: no jq" >&2; exit 2; }

sha_of() {
	if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else echo unavailable
	fi
}

# ⚠ The build DIRECTORIES are not the architectures: build/x86_64-strictenv is
# a variant of x86_64, not a third architecture. Every label below comes out of
# the manifest, so a directory somebody renamed cannot mislabel a section.
dirs=""
for d in "$BUILDS"/*; do
	[ -f "$d/build-manifest.json" ] || continue
	dirs="$dirs $(basename "$d")"
done
[ -n "$dirs" ] || { echo "release-notes: no build-manifest.json under $BUILDS" >&2; exit 2; }

# The floor is a property of the build environment and every build here uses
# the same one. If two manifests disagree, that is a finding and not something
# to paper over with the first value.
floor=""
for d in $dirs; do
	f=$(jq -r '.floor_glibc' "$BUILDS/$d/build-manifest.json")
	if [ -z "$floor" ]; then floor=$f
	elif [ "$floor" != "$f" ]; then
		echo "release-notes: manifests disagree about the floor: $floor and $f" >&2
		exit 2
	fi
done

printf '## cross-libc `dlopen` %s\n\n' "$TAG"
printf 'Load the host'"'"'s GPU drivers into a process that carries its own libc.\n'
printf 'See the [README](https://github.com/pkgforge-dev/cross-libc-dlopen#readme)\n'
printf 'for what the two gaps are and which one your symptom is.\n\n'

printf '**Built on glibc %s**, which is the floor every artefact here is held\n' "$floor"
printf 'to. An object needing a symbol version above it would fail to load inside\n'
printf 'a bundle whose glibc is older, so the build refuses to produce one and\n'
printf 'the packaging step refuses to publish one.\n\n'

# ------------------------------------------------------------- the changelog --
printf '### Changes\n\n'
prev=$(git -C "$ROOT" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
if [ -n "$prev" ]; then
	printf 'Since `%s`:\n\n' "$prev"
	range="$prev..$TAG"
else
	printf 'First release. Everything in the repository at `%s`:\n\n' "$TAG"
	range="$TAG"
fi
# ⚠ %s alone: no author, no date, no hash trailer. A changelog that names a
# tool in a commit subject would put it in the release body, which
# docs/conventions/git.md forbids.
#
# ⛔ Captured to a file, not piped into head. `git log ... | head` reports
# HEAD's status, so a git failure would read as success and the body would ship
# with an empty Changes section and no complaint. That is the exact trap
# docs/conventions/shell.md names, and this script had it.
_log=$(mktemp)
if git -C "$ROOT" log --no-merges --format='- %s' "$range" > "$_log" 2>/dev/null &&
   [ -s "$_log" ]; then
	head -50 "$_log"
	n=$(wc -l < "$_log" | tr -d ' ')
	[ "$n" -gt 50 ] && printf -- '- and %s more\n' "$((n - 50))"
else
	printf -- '- the commit range could not be read here; see the history\n'
fi
rm -f "$_log"
printf '\n'

# ------------------------------------------------------------- per artefact --
printf '### What each artefact needs\n\n'
printf 'Read from `build-manifest.json`, which is built from the objects\n'
printf 'themselves and ships inside both archives.\n\n'

for d in $dirs; do
	m=$BUILDS/$d/build-manifest.json
	a=$(jq -r '.arch' "$m")
	v=$(jq -r '.variant // "default"' "$m")
	if [ "$v" = default ]; then
		printf '#### %s\n\n' "$a"
	else
		printf '#### %s, `%s` variant\n\n' "$a" "$v"
	fi
	printf '| artefact | max `GLIBC_` | SONAME | entry points | sha256 |\n'
	printf '|---|---|---|---|---|\n'
	jq -r '.artifacts | to_entries[]
		| "| `\(.key)` | \(.value.max_glibc) | \(if .value.soname == "" then "n/a" else "`" + .value.soname + "`" end) | \(.value.entry_points) | `\(.value.sha256)` |"' "$m"
	printf '\n'
	printf 'Compiler: `%s`\n\n' "$(jq -r '.compiler' "$m")"
done

# ----------------------------------------------------------------- the assets --
printf '### Assets\n\n'
printf 'Each artefact ships three ways: loose, in the `.tar`, and in the `.zip`.\n'
printf '⛔ No archive contains a directory, so an extract drops the files where\n'
printf 'you are standing.\n\n'
printf '⭐ **Two variants.** The default reads `CROSS_LIBC_DLOPEN_ROOT` and also\n'
printf '`APPDIR`, which an AppImage runtime exports on its own. The `strictenv`\n'
printf 'assets read `CROSS_LIBC_DLOPEN_ROOT` and nothing else: take those if you\n'
printf 'want one spelling and no interop. All five objects differ between the\n'
printf 'two, so the variant ships as archives rather than loose files.\n\n'
printf '| asset | sha256 |\n|---|---|\n'
for f in "$DIST"/*; do
	[ -f "$f" ] || continue
	case "$f" in *.sha256) continue ;; esac
	printf '| `%s` | `%s` |\n' "$(basename "$f")" "$(sha_of "$f")"
done
printf '\n'
printf '⚠ The artefact rows above come from the manifest. The archive rows are\n'
printf 'computed here, because the archives did not exist when it was written.\n\n'

# --------------------------------------------------------------- how to use --
printf '### Using it\n\n'
printf '```\n'
printf 'LD_PRELOAD=/path/to/cross-libc-dlopen.so CROSS_LIBC_DLOPEN=1 ./your-program\n'
printf '```\n\n'
printf 'For a bundle, put the objects in its `lib/` and name them in `.preload`.\n'
printf 'The switches are in the README and\n'
printf '[`docs/integrating.md`](https://github.com/pkgforge-dev/cross-libc-dlopen/blob/main/docs/integrating.md)\n'
printf 'has the detail per target.\n'
