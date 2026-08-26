#!/bin/sh
# Do the documents still describe the tree?
#
# ⭐ More than one agent works on this repository, and they do not all have the
# same care. A convention that is only written down is followed by whoever read
# it; a convention with a check behind it is followed by everyone. This is the
# mechanical half of "documentation ships with the code it describes".
#
# Four questions, each reported separately so the failure names itself:
#
#   1. Every CROSS_LIBC_DLOPEN_* control the code reads is documented, and
#      every one the documents name is actually read. ⭐ This is the one that
#      matters most: a switch that stops working is invisible, because the
#      documented name and the read name look identical from either side.
#   2. Every repository path a document cites exists.
#   3. Every `make` target a document names exists in src/Makefile.
#   4. The dash ratchet. See docs/conventions/prose.md.
#
#   sh scripts/check-drift.sh
#
# Exit 0 everything agrees, 1 something drifted, 2 could not run.
set -u

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 2
command -v git >/dev/null 2>&1 || { echo "check-drift: no git" >&2; exit 2; }

fail=0
say()  { printf '  %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
head_() { printf '\n== %s ==\n' "$*"; }

# Documents that describe the CURRENT tree. HISTORY/ is excluded everywhere in
# this script on purpose: it records what was true when it was written, and
# says so at the top of every file.
docs() { git ls-files '*.md' ':(exclude)HISTORY/*'; }

# ------------------------------------- 1. the controls, both directions -----
head_ "environment controls: code against documents"

# What the code actually reads: every CROSS_LIBC_DLOPEN string literal in the
# implementation. That covers cld_getenv's first argument and the #defines in
# cld-env.h in one pass, without having to know which form each control uses.
git grep -hoE '"CROSS_LIBC_DLOPEN[A-Z_]*"' -- 'src/*.c' 'src/*.h' 2>/dev/null |
	tr -d '"' | sort -u > /tmp/cd_code.txt

# What the documents name. ⚠ A trailing underscore is the prefix being talked
# about ("the CROSS_LIBC_DLOPEN_ prefix"), not a control.
docs | tr '\n' '\0' | xargs -0 grep -hoE '\bCROSS_LIBC_DLOPEN[A-Z_]*' 2>/dev/null |
	grep -v '_$' | sort -u > /tmp/cd_docs.txt

# ⚠ Both directions. A control read but undocumented is a feature nobody can
# find; a control documented but never read is a switch that silently does
# nothing, which is the worse of the two because it looks like it works.
undocumented=$(comm -23 /tmp/cd_code.txt /tmp/cd_docs.txt)
unread=$(comm -13 /tmp/cd_code.txt /tmp/cd_docs.txt)

if [ -n "$undocumented" ]; then
	bad "read by src/ and named in no document:"
	printf '%s\n' "$undocumented" | sed 's/^/         /'
else
	say "every control src/ reads is documented ($(wc -l < /tmp/cd_code.txt | tr -d ' ') of them)"
fi
if [ -n "$unread" ]; then
	bad "named in a document and read by nothing in src/:"
	printf '%s\n' "$unread" | sed 's/^/         /'
	say "       a documented switch that nothing reads does nothing, silently."
else
	say "every control the documents name is read by src/"
fi

# ------------------------------------------- 2. cited paths still exist -----
head_ "cited paths"

# Repository-relative paths in backticks, anchored on a real top-level
# directory so /usr/lib and $APPDIR/lib are not mistaken for citations.
#
# ⚠ These paths belong to ANOTHER project and are cited as that project's own
# files: the first two are onelf's, which is Rust and has no src/main.rs here.
# Exempt BY NAME rather than by pattern, so adding one is a deliberate act and
# a typo in a path of ours is still caught.
foreign=" docs/guide/cross-libc.md src/main.rs src/utils.rs "

missing=0
docs | tr '\n' '\0' |
	xargs -0 grep -hoE '`(src|scripts|tests|tools|docs|experiments|examples|TODO|HISTORY|inventories)/[A-Za-z0-9_./-]+`' 2>/dev/null |
	tr -d '`' | sed 's/[.,)]*$//' | sort -u > /tmp/cd_paths.txt
while IFS= read -r p; do
	[ -n "$p" ] || continue
	case "$p" in */) continue ;; esac
	# A wildcard citation is a class, not a file.
	case "$p" in *\**) continue ;; esac
	case "$foreign" in *" $p "*) continue ;; esac
	[ -e "$p" ] || { bad "cited and does not exist: $p"; missing=$((missing + 1)); }
done < /tmp/cd_paths.txt
[ "$missing" = 0 ] && say "every cited path exists ($(wc -l < /tmp/cd_paths.txt | tr -d ' ') checked)"

# ----------------------------------------------- 3. make targets exist ------
head_ "make targets"

badt=0
docs | tr '\n' '\0' | xargs -0 grep -hoE '`make (-C src )?[a-z][a-z0-9-]*`' 2>/dev/null |
	tr -d '`' | sed 's/^make //; s/^-C src //' | sort -u > /tmp/cd_targets.txt
while IFS= read -r t; do
	[ -n "$t" ] || continue
	grep -qE "^$t:" src/Makefile || { bad "documented but not a target in src/Makefile: make $t"; badt=1; }
done < /tmp/cd_targets.txt
[ "$badt" = 0 ] && say "every documented make target exists"

# ------------------------------------------------- 4. the dash ratchet ------
head_ "dashes used as punctuation"

# ⛔ A RATCHET, NOT A GATE. The count may fall and may not rise. The tree this
# was written against carries the number below; rewriting all of them in one
# change would be a change nobody could review, so they go as the files they
# live in are touched for other reasons. When the count falls, lower BUDGET.
# docs/conventions/prose.md says why `--` is not the fix for an em dash.
BUDGET=236
have=$(docs | tr '\n' '\0' | xargs -0 grep -hoF ' -- ' 2>/dev/null | wc -l | tr -d ' ')
if [ "$have" -gt "$BUDGET" ]; then
	bad "$have dashes used as punctuation, and the budget is $BUDGET."
	say "       Rewrite the sentence rather than swapping one dash for another."
	say "       docs/conventions/prose.md has the four replacements."
elif [ "$have" -lt "$BUDGET" ]; then
	say "$have, down from a budget of $BUDGET. ⭐ Lower BUDGET in this script to $have."
else
	say "$have, at the budget. It may fall and may not rise."
fi

printf '\n'
if [ "$fail" = 0 ]; then
	printf '  the documents and the tree agree\n'
	exit 0
fi
printf '  the documents and the tree disagree. The document is usually the defect.\n'
exit 1
