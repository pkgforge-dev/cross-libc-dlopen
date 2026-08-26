#!/bin/sh
# The evidence table: three throwaway containers over one shared volume.
#
#   alpine:3.22           builds a faithful musl-linked probe library
#   debian:trixie-slim    builds libraries needing NEWER glibc symbols and
#                         stages that newer runtime
#   debian:bullseye-slim  glibc 2.31, the "older bundled glibc" under test
#
# Every experiment declares a prediction; the harness reports MATCH/MISMATCH.
# Exit 0 means every prediction held. This is the ~4 minute pre-commit gate.
#
#   scripts/run-evidence.sh              run it
#   scripts/run-evidence.sh --keep       keep the volume for poking at
#   CLD_ENGINE=docker scripts/run-evidence.sh
#
# ⛔ The stage scripts under experiments/ are the TESTS. This file sequences
# them and nothing more. Every `run`/`verdict` line in a stage states a
# prediction the harness scores; rewriting one changes what is measured.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(dirname -- "$HERE")
STAGES=$ROOT/experiments
. "$HERE/suite-lib.sh"

KEEP=0
VOLUME=${CLD_VOLUME:-cross-libc-dlopen}
while [ $# -gt 0 ]; do
	case "$1" in
		--keep) KEEP=1; shift ;;
		-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option $1" ;;
	esac
done

engine=$(resolve_engine)
say "engine: $engine"

# Deliberately NOT piped over stdin: a shell that re-encodes a piped string on
# its way to a native process corrupts the tail of the script and yields a
# bogus "sh: : not found" (exit 127) even though every command ran. Mounting
# the file sidesteps encoding entirely.
stage() {                              # stage <image> <script> <shell>
	_img=$1; _scr=$2; _sh=$3
	assert_lf "$STAGES/$_scr"
	info "==> $_img  ($_scr)"
	"$engine" run --rm \
		-v "$VOLUME:/work" \
		-v "$STAGES:/scripts:ro" \
		-v "$ROOT:/repo:ro" \
		"$_img" "$_sh" "/scripts/$_scr"
}

# A stale volume would silently reuse artefacts from a previous run.
"$engine" volume rm -f "$VOLUME" >/dev/null 2>&1 || true
cleanup() {
	if [ "$KEEP" = 1 ]; then say "volume '$VOLUME' kept"
	else "$engine" volume rm -f "$VOLUME" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

stage alpine:3.22          10-build-musl.sh     sh   || die "stage 1 failed"
stage debian:trixie-slim   20-build-newglibc.sh sh   || die "stage 2 failed"

rc=0
stage debian:bullseye-slim 30-run-tests.sh      bash || rc=$?

say ""
if [ "$rc" = 0 ]; then
	say "ALL PREDICTIONS HELD"
else
	warn "SOME PREDICTIONS DID NOT HOLD (exit $rc) -- investigate, this is a finding"
fi
exit "$rc"
