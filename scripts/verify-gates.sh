#!/bin/sh
# Can each gate actually refuse?
#
# ⭐ A gate never seen to refuse is a gate nobody knows works. This plants the
# exact defect each gate exists to catch, runs the gate's own body UNPIPED,
# reads the exit code, and then runs the same body against a CLEAN tree.
#
# ⛔ BOTH HALVES ARE REQUIRED. A gate that refuses a planted defect and ALSO
# refuses a clean tree is not working, it is stuck -- and two gates in this
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
	for n in 3470 358 46/46 45/45 40/40 26/26; do
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

# ⛔ NOT RESTATED. gates.yml runs this one as `sh scripts/check-drift.sh`, so
# the body here is that same call rather than a copy of its four sections: a
# copy is a second thing to keep in step, and the first one to drift.
g_drift() { sh scripts/check-drift.sh; }

echo "== each gate, against a clean tree and against its own defect =="

# ⛔ THE PLANTS ARE ASSEMBLED AT RUNTIME, and this is not decoration. Spelled
# out plainly they would sit in this file as literals, the gates would match
# THIS file, and every one of them would then refuse a clean tree -- which is
# precisely the defect this script exists to catch, reproduced one level up.
# It happened on the first run of this script.
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
	'the suite reports 46/46 predictions held'

# ⛔ THIS CHECK EXISTS BECAUSE THE RATCHET DID NOT REFUSE. It was written as a
# budget with a hardcoded number and a printed suggestion that the next reader
# lower it. Nobody did, the tree drifted eight under, and a planted dash then
# landed inside the slack and passed. Proving it by hand once proves it on the
# day; this proves it on every run. scripts/check-drift.sh section 4.
check "the dash ratchet refuses a new dash" g_drift docs/_gate_probe.md \
	'A sentence -- with a dash.'
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
