#!/bin/sh
# Which characters may appear in a file this repository authors?
#
# ASCII, plus the five markers docs/conventions/prose.md defines, plus any
# emoji. A glyph outside that set is a character a reader cannot type, cannot
# grep for, and may not see rendered the way the author saw it. Once one is
# load-bearing in a rule or a table, the rule is unreadable to somebody.
# Emoji are the exception: they are not load-bearing and a reader can see
# them, so they are permitted.
#
#   sh scripts/check-charset.sh
#
# Exit 0 clean, 1 a banned character is present, 2 could not run.
set -u

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 2
command -v git >/dev/null 2>&1 || { echo "check-charset: no git" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "check-charset: no perl" >&2; exit 2; }

# The file list comes from git, so an untracked file is out of scope without
# needing to be named. Binary files are excluded by -I rather than by
# extension.
files() { git ls-files; }

fail=0
seen=0

# ⛔ A banned character is permitted where it is NAMED rather than used, inside
# a code span or a fence. Without it the rule is unwritable: the page that bans
# a character could not show which one.
strip_quoted() {
	awk '
		FNR == 1           { fence = 0 }
		/^[ \t]*(```|~~~)/ { fence = !fence; print ""; next }
		fence              { print ""; next }
		                   { gsub(/`[^`]*`/, ""); print }
	'
}

for f in $(files); do
	grep -Iq . "$f" 2>/dev/null || continue      # binary, or unreadable
	seen=$((seen + 1))

	# Reported with the code point: "a strange character on line 40" is not
	# something a reader can act on. ⚠ -CSD decodes UTF-8, and without it a
	# marker reads as three banned bytes.
	out=$(strip_quoted < "$f" | perl -CSD -ne '
		while (/([^\x00-\x7F])/g) {
			my $c = $1;
			next if $c =~ /[\x{26D4}\x{2B50}\x{26A0}\x{2705}\x{274C}]/;
			next if $c =~ /[\x{1F300}-\x{1FAFF}\x{2190}-\x{21FF}\x{2300}-\x{23FF}\x{2500}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]/;
			printf "%d:U+%04X %s\n", $., ord($c), $c;
		}')

	[ -z "$out" ] && continue
	printf '%s\n' "$out" | while IFS= read -r hit; do
		printf '  FAIL %s:%s\n' "$f" "$hit"
	done
	fail=1
done

if [ "$fail" = 0 ]; then
	printf '  every tracked file is ASCII plus the five markers and any emoji (%s scanned)\n' "$seen"
	exit 0
fi

printf '\n'
printf '  docs/conventions/prose.md names the replacement for each of these.\n'
printf '  A character being NAMED rather than used belongs in a code span.\n'
exit 1
