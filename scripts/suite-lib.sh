#!/bin/sh
# Shared by scripts/run-evidence.sh and scripts/run-appimage.sh: everything the
# two PowerShell orchestrators did that was NOT sequencing.
#
# ⛔ THREE BEHAVIOURS HERE ARE LOAD-BEARING. They live in the orchestration
# layer rather than in a stage, so a port that only translated the sequencing
# would drop them and quietly change what the suite measures:
#
#   1. sha256 of every downloaded AppImage, verified, refusing to continue on
#      a mismatch. The suite's whole premise is that it drove a KNOWN binary.
#   2. a stage script containing CR is REJECTED, not run. A CR turns a shell
#      script into a $'...\r' "not found" error that names the wrong thing and
#      reads like anything but line endings.
#   3. the GPU capability is PROBED by running a container, not inferred from
#      the host. The engine may be a WSL2 VM, a Linux daemon or a remote
#      socket, and only the container's own view decides. The answer is what
#      makes ten cases run or SKIP by name.
#
# Not executable on its own; dot-sourced.

# --------------------------------------------------------------- reporting --
c_info=''; c_warn=''; c_off=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	c_info=$(printf '\033[36m'); c_warn=$(printf '\033[33m'); c_off=$(printf '\033[0m')
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$c_info" "$*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf 'suite: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------ 1. container engine --
# podman and docker interchangeably. No hardcoded path: the PowerShell version
# carried one Windows machine's podman location, which is a local convenience
# and has no business in a script other people run.
resolve_engine() {
	if [ -n "${CLD_ENGINE:-}" ]; then
		command -v "$CLD_ENGINE" >/dev/null 2>&1 ||
			die "CLD_ENGINE=$CLD_ENGINE is not on PATH"
		printf '%s' "$CLD_ENGINE"; return
	fi
	for e in podman docker; do
		if command -v "$e" >/dev/null 2>&1; then printf '%s' "$e"; return; fi
	done
	die "no container engine found. Install podman or docker, or set CLD_ENGINE."
}

# ------------------------------------------------------------ 2. CR refusal --
# ⚠ tr and cmp, NOT grep. Measured on this machine: a CR pattern built with
# $(printf '\r') matches nothing at all, so the grep form of this check reads
# GREEN over a file that demonstrably contains a CR. Carrying the PowerShell
# orchestrator's CR refusal across in that form would have carried it across as
# a no-op, looking exactly like the original and measuring nothing. This asks a
# different question: if deleting every CR changes the file, it had one.
assert_lf() {                          # assert_lf <file>
	[ -f "$1" ] || die "missing stage script: $1"
	if ! tr -d '\r' < "$1" | cmp -s - "$1"; then
		die "$1 contains CR characters. Stage scripts here must be LF-only;
      check core.autocrlf and .gitattributes. A CR makes every command in the
      file report 'not found' while naming something else entirely."
	fi
}

# --------------------------------------------------------------- 3. the GPU --
# Asked by RUNNING it. Sets GPU_ARGS to the flags that worked, or to nothing.
# A machine with no GPU is a supported configuration: the cases that need one
# then SKIP by name, which is the mechanism CI needs and it already exists.
GPU_ARGS=''
probe_gpu() {                          # probe_gpu <engine>
	_e=$1
	# WSL2's paravirtual GPU: /dev/dxg plus the vendor userspace bind-mounted
	# from the host. This is the only GPU route the machine this was written
	# on has; a Linux host with /dev/dri needs its own candidate set here.
	_cand='--device /dev/dxg -v /usr/lib/wsl:/usr/lib/wsl:ro'
	# shellcheck disable=SC2086
	if _out=$("$_e" run --rm $_cand alpine:3.22 sh -c \
	          'test -e /dev/dxg && test -f /usr/lib/wsl/lib/libcuda.so.1 && echo GPU-OK' 2>&1) &&
	   printf '%s' "$_out" | grep -q GPU-OK; then
		GPU_ARGS=$_cand
		say "GPU: /dev/dxg and the WSL vendor userspace are reachable"
		return 0
	fi
	GPU_ARGS=''
	say "GPU: none reachable from a container here; the hardware cases will SKIP by name"
	return 0
}

# --------------------------------------------------------------- 4. sha256 --
sha256_of() {
	if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
	else die "no sha256sum or shasum; cannot verify a download and will not skip the check"
	fi
}

# ⭐ WHAT GITHUB SAYS THE ASSET IS, which is a different question from what we
# pinned and from what arrived. The release API publishes a sha256 per asset,
# so it can be read without downloading anything. Printing nothing on any
# failure is deliberate: this only ever ADDS a sentence to a refusal, and a
# suite that cannot reach the network must still be able to refuse.
#
# ⚠ awk over `tr ',' '\n'`, not jq and not python3. The suite runs on a hosted
# runner, in Git Bash on Windows and inside four container images, and jq is
# not on all of them. Splitting on commas cuts through string values too; that
# is harmless here because the only lines this reads are a name and a digest,
# and their order in the response is what identifies the pair.
upstream_digest() {                    # upstream_digest <owner/repo> <tag> <asset>
	command -v curl >/dev/null 2>&1 || return 0
	curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null |
	tr ',' '\n' | awk -v want="$3" '
		/"name":[ ]*"/ {
			n = $0; sub(/.*"name":[ ]*"/, "", n); sub(/".*/, "", n)
		}
		/"digest":[ ]*"sha256:/ {
			if (n == want) {
				d = $0; sub(/.*sha256:/, "", d); sub(/[^0-9a-f].*/, "", d)
				print d; exit
			}
		}'
}

# ⛔ THREE THINGS CAN DISAGREE AND THE OLD MESSAGE SAID ONE SENTENCE FOR ALL OF
# THEM: our pin, the bytes that arrived, and what the upstream release
# publishes today. Which pair differs decides what a reader should do, and they
# are not close to each other.
#
# ⚠ Measured, and it is why this exists. Run 32948154287 refused with "sha256
# is 8f6e390a..., expected 712766f8...". That reads as one event. It was not:
# the asset had already been replaced before the run started, and every asset
# on that release was replaced AGAIN at 08:32:37Z, 56 seconds after the run
# ended. The upstream tag is `demo` and it is mutable, so this recurs by
# design. docs/REPORT.md 9.15.
fetch_verified() {                     # fetch_verified <url> <dest> <sha256> <label> [repo tag asset]
	_url=$1; _dst=$2; _want=$3; _label=$4
	_repo=${5:-}; _tag=${6:-}; _asset=${7:-}
	if [ ! -f "$_dst" ]; then
		say "downloading $_label"
		mkdir -p "$(dirname "$_dst")"
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL -o "$_dst.part" "$_url" || die "download failed: $_url"
		elif command -v wget >/dev/null 2>&1; then
			wget -q -O "$_dst.part" "$_url" || die "download failed: $_url"
		else
			die "no curl or wget to fetch $_url"
		fi
		mv "$_dst.part" "$_dst"
	fi
	_got=$(sha256_of "$_dst")
	if [ "$_got" = "$_want" ]; then
		say "$_label sha256 ok"
		return 0
	fi

	_pub=''
	[ -n "$_repo" ] && _pub=$(upstream_digest "$_repo" "$_tag" "$_asset")

	if [ -z "$_pub" ]; then
		_why="Upstream was not reachable, so which of the two changed is not
      established here. Re-run with the network, or check by hand."
	elif [ "$_pub" = "$_got" ]; then
		_why="UPSTREAM RE-UPLOADED IT. What arrived is exactly what the release
      publishes today, so the pin is older than the asset and nothing is wrong
      with the download. ⛔ Re-pinning is a deliberate, reviewed act and not a
      way to make this green: read docs/REPORT.md 9.15 before you do it."
	elif [ "$_pub" = "$_want" ]; then
		_why="⛔ THE DOWNLOAD IS WRONG, NOT THE PIN. The release still publishes
      the pinned digest, so these bytes were truncated, cached wrong, or
      substituted in transit. Delete $_dst and retry. If it repeats, stop and
      do not re-pin."
	else
		_why="⛔ NEITHER MATCHES. Upstream publishes $_pub, which is a third
      value, so the asset changed AND what arrived is not the new asset
      either. A read torn by a re-upload in progress looks exactly like this,
      and so does interception. Retry once; if the retry lands on $_pub the
      first read was torn."
	fi

	die "$_label sha256 is $_got, expected $_want.
      $_why
      Refusing to continue: every result below would be about a binary nobody
      pinned."
}

# ------------------------------------------------------- 5. the architecture --
# Obstacles 2 and 3 of PORTING 5.0: the suite was locked to x86-64 by the
# loader name, the musl soname and the two asset URLs. All four derive from
# uname -m instead.
suite_arch() { printf '%s' "${CLD_TARGET_ARCH:-$(uname -m)}"; }

asset_suffix() {                       # the upstream release's arch suffix
	case "$(suite_arch)" in
		x86_64|amd64)   printf 'x86_64' ;;
		aarch64|arm64)  printf 'aarch64' ;;
		*) die "no upstream demo AppImage is published for $(suite_arch)" ;;
	esac
}
