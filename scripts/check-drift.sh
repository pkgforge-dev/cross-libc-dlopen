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
# ⛔ THE PREFIX IS WHY THIS MISSED ONE. The first version of this anchored the
# path on the opening backtick and required a closing backtick straight after
# it, so it only ever saw a path cited alone. This repository's most common
# citation is not that shape: it is a COMMAND, `sh scripts/check-drift.sh`,
# and every one of those was invisible. docs/conventions/prose.md named
# `sh scripts/check-prose-dashes.sh` as the dash ratchet for the whole life of
# the branch. No such script has ever existed. The check that exists to catch
# a stale citation could not see a stale citation about itself.
#
# So: allow any run of backtick-free, space-terminated words between the
# opening backtick and the path, and drop the closing-backtick requirement so
# a path followed by its arguments still counts. Then pull the path back out
# of whatever matched.
#
# ⚠ `*` IS IN THE PATH CLASS ON PURPOSE. `src/gl-fwd-*.h` is a class of files,
# not a file, and the skip below drops it. Leave `*` out and the class stops
# at the hyphen, the wildcard skip never sees a wildcard, and the check
# reports `src/gl-fwd-` missing. That is not hypothetical: it is what the
# widened pattern did on its first run.
#
# ⚠ These paths belong to ANOTHER project and are cited as that project's own
# files: the first three are onelf's, which is Rust and has no src/main.rs
# here, and the fourth is Azathothas/TEMPLATE's, which docs/AGENTS.md cites at
# a URL and says in the same sentence is not in this tree. `tests/bindprobe`
# is ours and is a BUILT binary, so it is cited as a command and is not, and
# should not be, a tracked file.
# Exempt BY NAME rather than by pattern, so adding one is a deliberate act and
# a typo in a path of ours is still caught.
foreign=" docs/guide/cross-libc.md src/main.rs src/utils.rs docs/methodology/references.md tests/bindprobe "

# ⚠ A FENCED BLOCK IS A TRANSCRIPT, NOT A CITATION, and this check skips one.
# docs/REPORT.md's evidence is quoted command output, and output that records a
# failure names the path that was wrong. Without this, the one document whose
# job is to record a broken-path finding is the one document that cannot quote
# it. Measured before the exemption went in: 88 paths cited with fences read,
# 88 with fences skipped, and no path anywhere in the tree is cited ONLY inside
# a fence. It costs no coverage on this tree. Backticks in running text are
# still read, which is where a stale citation actually misleads somebody.
unfenced() {
	docs | tr '\n' '\0' | xargs -0 awk '
		FNR == 1     { fence = 0 }
		/^[ \t]*(```|~~~)/ { fence = !fence; next }
		fence        { next }
		             { print }
	' 2>/dev/null
}

anchor='(src|scripts|tests|tools|docs|experiments|examples|TODO|HISTORY|inventories)/[A-Za-z0-9_./*-]+'
missing=0
unfenced |
	grep -hoE "\`([^\` ]+ )*$anchor" 2>/dev/null |
	grep -oE "$anchor" | sed 's/[.,)]*$//' | sort -u > /tmp/cd_paths.txt
while IFS= read -r p; do
	[ -n "$p" ] || continue
	case "$p" in */) continue ;; esac
	# A wildcard citation is a class, not a file.
	case "$p" in *\**) continue ;; esac
	case "$foreign" in *" $p "*) continue ;; esac
	[ -e "$p" ] || { bad "cited and does not exist: $p"; missing=$((missing + 1)); }
done < /tmp/cd_paths.txt
[ "$missing" = 0 ] && say "every cited path exists ($(wc -l < /tmp/cd_paths.txt | tr -d ' ') checked)"

# ------------------------------------ 2b. every tool import is reachable ----
head_ "python imports"

# ⛔ THIS CHECK EXISTS BECAUSE OF T-14. tools/libc_inventory.py was recorded as
# "not run by anything", measured by grep over the tree. The grep was real and
# it searched for the FILENAME; tools/gen_forward_shim.py imports it by MODULE
# name, and `make shim` runs that generator on every push. Moving the file
# broke the generator, and the generator's own error was hidden behind a
# 2>/dev/null two layers away.
#
# A module is reachable if it sits in the importer's own directory or in one of
# the directories that file inserts into sys.path. Both forms below appear in
# this tree: __file__'s directory, and its parent.
badi=0
for f in $(git ls-files 'tools/*.py'); do
	d=$(dirname "$f")
	for m in $(sed -n 's/^from \([a-z_][a-z_0-9]*\) import .*/\1/p' "$f"); do
		# Standard library and packages are not ours to resolve.
		case "$m" in
			os|sys|re|json|struct|io|lzma|tarfile|urllib|argparse|shutil|\
			hashlib|glob|tempfile|textwrap|collections|itertools|pathlib|typing|subprocess)
				continue ;;
		esac
		if [ -f "$d/$m.py" ] || [ -f "$(dirname "$d")/$m.py" ]; then
			continue
		fi
		bad "$f imports '$m' and no $m.py is reachable from $d/ or its parent"
		badi=1
	done
done
[ "$badi" = 0 ] && say "every module a tool imports is beside it or one level up"

# ------------------------------------ 2c. nothing enters that does not belong --
head_ "what is tracked"

# ⛔ THIS CHECK EXISTS BECAUSE IT HAPPENED. `git add -A` after a packaging run
# took 22 files and 6.7 MB of built objects into the index, in a repository
# whose entire output is reproducible from source. .gitignore covered build/
# and not dist/, and nothing else was looking.
#
# The rule is by SHAPE, not by directory: an ELF object, an archive or an
# AppImage has no business being tracked here whatever it is called.
badf=0
for f in $(git ls-files); do
	case "$f" in
		*.so|*.so.[0-9]*|*.o|*.a|*.tar|*.tar.*|*.zip|*.AppImage|*.gz|*.xz)
			bad "tracked build output or archive: $f"; badf=1 ;;
	esac
done
# And anything executable-shaped that is not a script or a source file.
for f in $(git ls-files); do
	case "$f" in
		*.sh|*.py|*.ps1|*.c|*.h|*.md|*.json|*.yml|*.yaml|*/Makefile|Makefile|LICENSE|.git*) continue ;;
	esac
	if [ -f "$f" ] && head -c 4 "$f" 2>/dev/null | grep -q 'ELF'; then
		bad "tracked ELF binary: $f"; badf=1
	fi
done
[ "$badf" = 0 ] && say "nothing tracked that this repository builds"

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

# ------------------------------- 3b. the two orchestrators pin one thing ----
head_ "the AppImage pins, both orchestrators"

# ⛔ THIS CHECK EXISTS BECAUSE THEY DIVERGED. scripts/run-appimage.sh and
# experiments/appimage.ps1 run the same stage scripts against the same two
# downloads, and each carries its own copy of the sha256 pair. A change that
# re-pinned the shell side left the PowerShell side refusing on the old hash,
# and docs/reproducing.md sends a reader on a machine without a POSIX shell to
# exactly that file. A pin in two files is one pin and two chances to be wrong.
#
# ⚠ The PowerShell orchestrator is x86_64 only, so it is compared against the
# x86_64 branch of the shell one and nothing is inferred about aarch64.
sh_pins=$(sed -n '/x86_64)/,/aarch64)/p' scripts/run-appimage.sh |
          grep -oE '[0-9a-f]{64}' | sort | tr '\n' ' ')
ps_pins=$(grep -oE '[0-9a-f]{64}' experiments/appimage.ps1 | sort | tr '\n' ' ')
if [ -z "$sh_pins" ] || [ -z "$ps_pins" ]; then
	bad "could not read a sha256 pin out of one of the orchestrators."
	say "       shell: [$sh_pins]"
	say "       pwsh : [$ps_pins]"
elif [ "$sh_pins" != "$ps_pins" ]; then
	bad "the two orchestrators pin different bytes."
	say "       scripts/run-appimage.sh   x86_64: $sh_pins"
	say "       experiments/appimage.ps1        : $ps_pins"
	say "       Both drive the same stages. docs/REPORT.md 9.15 has the policy."
else
	say "both orchestrators pin the same two assets"
fi

# ------------------------------------------------- 4. the dash ratchet ------
head_ "dashes used as punctuation"

# ⛔ A RATCHET, AND THE PIN IS EXACT. The count may fall and may not rise, and
# a FALL refuses too. That second half is not pedantry: it is the only thing
# that carries the pin down, and without it the ratchet stops ratcheting.
#
# ⚠ MEASURED, AND THIS IS WHY. The pin was set to 236 at bc29fce, when the
# tree carried 236. e09e128 took the tree to 235 and f6d126e took it to 228,
# and neither lowered the pin, because the only thing asking them to was a
# suggestion this script printed and nobody read. Eight of slack later, a
# planted dash raises 228 to 229, which is under 236, so the check reports
# "down from a budget" and exits 0. A session planted exactly that dash, read
# exactly that, and recorded the ratchet as broken. The count was never wrong.
# The guard was unarmed, and a ratchet that only ever suggests tightening
# never tightens. docs/REPORT.md 9.14 has both halves proven.
#
# Rewriting every dash in one change would be a change nobody could review, so
# they go as the files they live in are touched for other reasons, and each
# such change lowers the number below in the same commit.
# docs/conventions/prose.md says why `--` is not the fix for an em dash.
# ⚠ PROSE ONLY, and the rule is the reason. docs/conventions/prose.md exempts
# `--` doing its own job: a command-line flag, a literal inside a code block, a
# shell comment. The first version of this counted those too, so a document
# that added a correct shell snippet was refused, and a rewrite that traded a
# prose dash for a code one netted to zero and passed. Measured on the tree
# this was written against: 233 counted raw, 15 of them inside a fence or a
# span, 218 actually prose. It also made this section unwritable, because
# recording the planted sentence puts the planted sentence in a document.
#
# A fence toggles on ``` or ~~~ and resets per file. Both are markdown, and a
# transcript that quotes one has to open with the other. A code span is
# stripped from the lines that are left.
count_dashes() {
	docs | tr '\n' '\0' | xargs -0 awk '
		FNR == 1           { fence = 0 }
		/^[ \t]*(```|~~~)/ { fence = !fence; next }
		fence              { next }
		                   { gsub(/`[^`]*`/, ""); print }
	' 2>/dev/null | grep -oF ' -- ' | wc -l | tr -d ' '
}

BUDGET=218
have=$(count_dashes)
if [ "$have" -gt "$BUDGET" ]; then
	bad "$have dashes used as punctuation, and the pin is $BUDGET."
	say "       Rewrite the sentence rather than swapping one dash for another."
	say "       docs/conventions/prose.md has the four replacements."
elif [ "$have" -lt "$BUDGET" ]; then
	bad "$have dashes used as punctuation, and the pin is still $BUDGET."
	say "       The count fell, which is the point of the ratchet. Set BUDGET to"
	say "       $have in scripts/check-drift.sh, in this same change. Left alone"
	say "       the slack accumulates and the ratchet stops being able to refuse."
else
	say "$have, at the pin. It may fall, and a fall lowers the pin with it."
fi

# ------------------------------- 5. INDEX agrees with the entries -----------
head_ "TODO/INDEX.md against the entries"

# ⛔ THIS CHECK EXISTS BECAUSE IT DRIFTED. docs/AGENTS.md scenario 10 says a
# session reconciles INDEX.md's counts on the way out. Two entries closed in
# place and declared themselves DONE, and INDEX went on listing one as open and
# the other as partially done for the rest of the branch. A list that disagrees
# with the things it lists is worse than no list, because it is the thing a
# reader checks FIRST and the entry is the thing they check last.
#
# The entry is the authority: it is where the acceptance command was run and
# the output recorded. INDEX is a view of it.
#
# ⚠ An entry's status may carry a trailing clause, "partially done -- see
# somewhere". Everything from the first dash on is a pointer, not a status.
badx=0
entries=$(git ls-files 'TODO/*.md' |
          grep -vE 'TODO/(INDEX|PROGRESS|RULES)\.md')
# shellcheck disable=SC2086
awk '
	/^## T-[0-9]+/            { id = $2; next }
	/\*\*Status\*\*/ && id != "" {
		s = $0
		sub(/.*\*\*Status\*\*[ ]*/, "", s)
		gsub(/[⭐*]/, "", s)
		sub(/ -- .*/, "", s)
		gsub(/^[ ]+|[ ]+$/, "", s)
		print id "\t" tolower(s)
		id = ""
	}' $entries > /tmp/cd_entry_status.txt

while IFS="$(printf '\t')" read -r id st; do
	[ -n "$id" ] || continue
	row=$(grep -E "^\| $id \|" TODO/INDEX.md | head -1)
	if [ -z "$row" ]; then
		bad "$id has an entry and no row in TODO/INDEX.md"; badx=1; continue
	fi
	idx=$(printf '%s' "$row" | awk -F'|' '{print $6}' |
	      sed 's/^ *//; s/ *$//' | tr 'A-Z' 'a-z')
	if [ "$idx" != "$st" ]; then
		bad "$id: the entry says '$st', TODO/INDEX.md says '$idx'"
		say "       The entry is the authority. It is where the acceptance"
		say "       command was run. Fix the row, not the entry."
		badx=1
	fi
done < /tmp/cd_entry_status.txt
[ "$badx" = 0 ] && say "every entry's status matches its row ($(wc -l < /tmp/cd_entry_status.txt | tr -d ' ') checked)"

printf '\n'
if [ "$fail" = 0 ]; then
	printf '  the documents and the tree agree\n'
	exit 0
fi
printf '  the documents and the tree disagree. The document is usually the defect.\n'
exit 1
