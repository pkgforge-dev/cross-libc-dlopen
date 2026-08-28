#!/bin/sh
# Run the template's secret sweep and decide what its findings mean HERE.
#
# ⛔ The check ships from Azathothas/TEMPLATE, so it cannot be narrowed at
# source. This is the call site, and it narrows by NAME, in two categories, both
# measured false positives, neither of them a credential:
#
#   an email address       one deliberate fixture, on a reserved non-routable
#                          domain, in scripts/verify-gates.sh.
#   a long hex identifier  git commit SHAs used as citations, and the sha256
#                          of the demo AppImage build the ground-truth
#                          inventory was measured against.
#                          ⛔ The digest is the point. It names the binary a
#                          measured answer is about; removing it would make
#                          the answer uncheckable.
#
# ⛔ EVERY OTHER CATEGORY IS STILL FATAL, including one that does not exist
# yet. A narrowing that silently swallows a category nobody predicted is worse
# than no check, and the workflow plants a category on every run and requires
# this script to refuse it.
#
# ⚠ The email category is allowed by NAME **and** re-checked by SHAPE. Allowing
# it by name alone would let a genuine address through under a rule written for
# a fixture, and an address is exactly the fingerprint --public exists to find.
# The hex category is allowed by name alone: every long hex string in this tree
# is a citation or a measured digest, and the template's own header says a generic
# entropy rule is deliberately absent because it fires on hashes.
#
#   sh scripts/sweep-known-benign.sh [path-to-check-no-secrets.sh]
#
# Exit 0 nothing but the two known-benign categories, 1 anything else, 2 could
# not run.
set -u

CHECK=${1:-/tmp/check-no-secrets.sh}
[ -f "$CHECK" ] || { echo "sweep: no check script at $CHECK" >&2; exit 2; }

OUT=$(mktemp) || exit 2
CATS=$(mktemp) || exit 2
REST=$(mktemp) || exit 2
trap 'rm -f "$OUT" "$CATS" "$REST"' EXIT INT TERM

# ⛔ Unpiped. The check's own status is what matters; through a pipe this would
# read the pipeline's, and a sweep that found something would report green.
sh "$CHECK" --public > "$OUT" 2>&1
rc=$?

cat "$OUT"

if [ "$rc" -eq 0 ]; then
	echo
	echo "  the sweep found nothing at all."
	exit 0
fi

fail=0
echo
echo "== deciding what those categories mean here =="

# Every category the sweep reported, one per line.
sed -n 's/^== \(.*\) ==$/\1/p' "$OUT" > "$CATS"

# ---------------------------------------------------- 1. unknown categories --
grep -vxF -e 'an email address' -e 'a long hex identifier' "$CATS" > "$REST" || true
if [ -s "$REST" ]; then
	echo
	echo "⛔ a category this repository has NOT measured as benign:"
	sed 's/^/     /' "$REST"
	echo "   Read it before doing anything else. If it is a real credential,"
	echo "   rotate first -- the check's own output says in what order."
	fail=1
fi

# ------------------------------------------------- 2. the email, by shape ---
# The lines the sweep filed under the email category, with the reserved,
# non-routable domains removed. Anything left is an address on a domain that
# could belong to somebody.
awk '/^== an email address ==$/ { f = 1; next } /^== / { f = 0 } f' "$OUT" |
	grep -vE '^[[:space:]]*$' |
	grep -vE '@[A-Za-z0-9.-]*\.(invalid|test|example|localhost)([^A-Za-z0-9.-]|$)' |
	grep -vE '@example\.(com|net|org)([^A-Za-z0-9.-]|$)' > "$REST" || true
if [ -s "$REST" ]; then
	echo
	echo "⛔ an email address that is NOT on a reserved non-routable domain:"
	sed 's/^/     /' "$REST"
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	echo
	echo "  only the two known-benign categories, and the email matches are all"
	echo "  on reserved domains. See the header of this script for why each is"
	echo "  benign and what would make it stop being benign."
	exit 0
fi
exit 1
