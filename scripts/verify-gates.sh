#!/bin/sh
# Can each gate actually refuse?
#
# ⭐ A gate never seen to refuse is a gate nobody knows works. This plants the
# exact defect each gate exists to catch, runs the gate's own body UNPIPED,
# reads the exit code, and then runs the same body against a CLEAN tree.
#
# ⛔ BOTH HALVES ARE REQUIRED. A gate that refuses a planted defect and ALSO
# refuses a clean tree is not working, it is stuck, and two gates in this
# repository were exactly that when this script was first run, because each
# pattern matched the line of the workflow it was written on.
#
#   sh scripts/verify-gates.sh
#
# ⚠ It stages and unstages files under the repository. It never commits, and it
# restores the index on the way out, but do not run it over uncommitted work.
set -u
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" || exit 2

if [ -n "$(git status --porcelain)" ]; then
	echo "refusing to run over a dirty tree: commit or stash first" >&2
	exit 2
fi

pass=0; bad=0
PLANTED=''

cleanup() {
	[ -n "$PLANTED" ] || return 0
	git rm -q -f --cached "$PLANTED" >/dev/null 2>&1
	rm -f "$PLANTED"
	PLANTED=''
}
trap 'cleanup' EXIT INT TERM

plant() {                              # plant <path> <content>
	PLANTED=$1
	printf '%s\n' "$2" > "$1"
	git add -f "$1" >/dev/null 2>&1
}

# ⛔ AN EXEMPTION IS A CLAIM AND IT NEEDS PROVING TOO. check() asserts that a
# plant makes the gate refuse. This asserts the opposite: the gate stays green
# with the content present, which is what an exemption means. Without it an
# exemption could quietly stop applying and nothing would say so, and the two
# checks here would become unwritable at the same moment.
check_exempt() {                       # check_exempt <name> <gate-fn> <path> <content>
	name=$1; fn=$2; path=$3; body=$4
	"$fn" >/dev/null 2>&1; clean=$?
	plant "$path" "$body"
	"$fn" >/dev/null 2>&1; dirty=$?
	cleanup
	if [ "$clean" -eq 0 ] && [ "$dirty" -eq 0 ]; then
		printf '  ok    clean=0 exempt=0    %s\n' "$name"
		pass=$((pass + 1))
	elif [ "$clean" -ne 0 ]; then
		printf '  STUCK clean=%-2s            %s   <-- refuses a CLEAN tree\n' "$clean" "$name"
		bad=$((bad + 1))
	else
		printf '  LOST  clean=0 exempt=%-2s   %s   <-- the exemption stopped applying\n' "$dirty" "$name"
		bad=$((bad + 1))
	fi
}

check() {                              # check <name> <gate-fn> <path> <content>
	name=$1; fn=$2; path=$3; body=$4
	"$fn" >/dev/null 2>&1; clean=$?
	plant "$path" "$body"
	"$fn" >/dev/null 2>&1; dirty=$?
	cleanup
	if [ "$clean" -eq 0 ] && [ "$dirty" -ne 0 ]; then
		printf '  ok    clean=0 planted=%-2s  %s\n' "$dirty" "$name"
		pass=$((pass + 1))
	elif [ "$clean" -ne 0 ]; then
		printf '  STUCK clean=%-2s            %s   <-- refuses a CLEAN tree\n' "$clean" "$name"
		bad=$((bad + 1))
	else
		printf '  DEAD  clean=0 planted=0   %s   <-- the gate is decorative\n' "$name"
		bad=$((bad + 1))
	fi
}

# --- the gate bodies, which must stay identical to .github/workflows/gates.yml -
g_oldname() {
	git grep -nIi -e 'dlope[n]-experiment' -e 'dlope[n].experiment' -- . && return 1
	return 0
}
g_attrib() {
	f=0
	tool='clau[d]e|copilo[t]|gp[t]|gemin[i]|anthropi[c]|opena[i]'
	git grep -nIiE "co-authored-by:.*($tool)" -- . && f=1
	git grep -nIiE "generated with \[?($tool)" -- . && f=1
	return $f
}
g_onehome() {
	f=0
	for n in 3470 358 53/53 50/50 45/45 40/40 26/26; do
		c=$(git grep -lF "$n" -- '*.md' ':(exclude)HISTORY/*' | wc -l)
		[ "$c" -gt 1 ] && f=1
	done
	return $f
}
g_parse() {
	f=0
	for s in $(git ls-files '*.sh'); do sh -n "$s" || f=1; done
	return $f
}
g_cr() {
	f=0
	for s in $(git ls-files '*.sh'); do
		tr -d '\r' < "$s" | cmp -s - "$s" || f=1
	done
	return $f
}
g_endings() {
	[ -z "$(git ls-files --eol | grep -v 'i/lf' | grep -v 'i/-text')" ]
}

# ⛔ NOT RESTATED. gates.yml runs these as `sh scripts/check-drift.sh` and
# `sh scripts/check-charset.sh`, so the bodies here are those same calls rather
# than copies of their sections: a copy is a second thing to keep in step, and
# the first one to drift.
g_drift() { sh scripts/check-drift.sh; }
g_charset() { sh scripts/check-charset.sh; }

echo "== each gate, against a clean tree and against its own defect =="

# ⛔ THE PLANTS ARE ASSEMBLED AT RUNTIME, and this is not decoration. Spelled
# out plainly they would sit in this file as literals, the gates would match
# THIS file, and every one of them would then refuse a clean tree, which is
# precisely the defect this script exists to catch, reproduced one level up.
# It happened on the first run of this script.
# ⚠ THE DASH AND THE CHARACTER ARE ASSEMBLED TOO, for the same reason as the
# names below: written plainly they would make THIS file a violation of the two
# checks it is proving, and both would then refuse a clean tree.
DASH2="-""- "
DASH1="-""-"
SECTION=$(printf '\302\247')
OLD_REPO="dlopen""-experiment"
OLD_REPO_US="dlopen""_experiment"
TOOLNAME="Clau""de"

check "the old repository name is gone" g_oldname docs/_gate_probe.md \
	"see https://github.com/Azathothas/$OLD_REPO/issues/1"
check "  the same, hyphen turned into an underscore" g_oldname docs/_gate_probe.md \
	"the $OLD_REPO_US repository"
check "no tool is credited (tree)" g_attrib docs/_gate_probe.md \
	"Co-Authored-By: $TOOLNAME Opus 5 <noreply@example.invalid>"
check "  the same, as a generated-with line" g_attrib docs/_gate_probe.md \
	"Generated with [$TOOLNAME Code](https://example.invalid)"
check "every headline number has one home" g_onehome docs/_gate_probe.md \
	'the suite reports 53/53 predictions held'

# ⛔ THIS CHECK EXISTS BECAUSE THE RATCHET DID NOT REFUSE. It was written as a
# budget with a hardcoded number and a printed suggestion that the next reader
# lower it. Nobody did, the tree drifted eight under, and a planted dash then
# landed inside the slack and passed. It carries no number now, and proving
# that by hand once proves it on the day; this proves it on every run.
# scripts/check-drift.sh section 4.
check "a dash used as punctuation is refused" g_drift docs/_gate_probe.md \
	"A sentence ${DASH2}with a dash."
# ⚠ THE WRAPPED FORM IS A SEPARATE CASE. The check matched only a dash with a
# space after it, so a paragraph breaking straight after the dash was invisible
# to it for the whole life of the ratchet. 17 were in the tree when that was
# found, one of them in docs/conventions/git.md.
check "  the same, wrapping at end of line" g_drift docs/_gate_probe.md \
	"A sentence ending ${DASH1}
and continuing here."
check "a banned character is refused" g_charset docs/_gate_probe.md \
	"A planted section sign ${SECTION} in running prose."

# ⛔ AND THE RULE MUST STAY WRITABLE. A dash or a character inside a code span
# is being NAMED, not used. Without these two exemptions the page that states
# each rule cannot show what it bans, and this file cannot record the plants
# above. docs/conventions/prose.md depends on both.
check_exempt "  a dash in a code span is a specimen" g_drift docs/_gate_probe.md \
	"The rule bans \`${DASH2}\` and names its replacement."
check_exempt "  a character in a code span is a specimen" g_charset docs/_gate_probe.md \
	"The rule bans \`${SECTION}\` and names its replacement."
check "shell scripts parse" g_parse scripts/_gate_probe.sh \
	'if [ 1 ; then'

# A CR cannot survive `plant`, which writes a trailing newline of its own, so
# this one plants directly.
g_cr >/dev/null 2>&1; clean=$?
PLANTED=scripts/_gate_probe.sh
printf 'echo hi\r\n' > "$PLANTED"; git add -f "$PLANTED" >/dev/null 2>&1
g_cr >/dev/null 2>&1; dirty=$?
cleanup
if [ "$clean" -eq 0 ] && [ "$dirty" -ne 0 ]; then
	printf '  ok    clean=0 planted=%-2s  %s\n' "$dirty" "no CR in a shell script"
	pass=$((pass + 1))
else
	printf '  BAD   clean=%-2s planted=%-2s  %s\n' "$clean" "$dirty" "no CR in a shell script"
	bad=$((bad + 1))
fi

# The endings gate reads the INDEX, so a planted CRLF file is normalised on the
# way in by .gitattributes and cannot reach it. Reported as unproven rather
# than as passing.
g_endings && echo "  --    clean=0             line endings match .gitattributes (clean only; see below)" \
          || echo "  STUCK                     line endings match .gitattributes"

echo
echo "  $pass gate(s) proven, $bad not"
echo
echo "  ⚠ NOT PROVEN HERE:"
echo "     - the endings gate. .gitattributes normalises a CRLF file on the way"
echo "       into the index, so the defect cannot be planted from this side."
echo "     - anything that needs a runner: the build matrix, the artefact"
echo "       verifier's floor rule, and the generated-table checks."
echo "       TODO/infrastructure.md T-10 is where those are tracked."
[ "$bad" -eq 0 ]
