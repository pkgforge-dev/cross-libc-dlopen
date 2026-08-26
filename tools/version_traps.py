#!/usr/bin/env python3
"""
Find the symbols a libc exports at SEVERAL versions with DIFFERENT code behind
them -- the set an *unversioned* reference can silently bind to the wrong one.

Why this exists
---------------
`cross-libc-dlopen.c` makes a host object loadable against our libc by removing
its symbol version requirements.  Every reference then becomes a plain name
lookup.  For most symbols that is exactly what we want.  For a symbol glibc
still exports at an obsolete version it is a trap: the unversioned lookup does
not pick the default definition, it picks the old one.

Measured, glibc 2.41, x86-64:

    pthread_cond_init@GLIBC_2.2.5   -> __pthread_cond_init_2_0, which is
                                       `if (attr != NULL) return EINVAL;`
    pthread_cond_init@@GLIBC_2.3.2  -> the real one

An object whose versions were stripped -- and equally, ANY musl-built object,
which never had versions -- gets the first one and every conditional-variable
initialisation with an attribute fails with EINVAL.  That is the whole reason
Mesa reported VK_ERROR_OUT_OF_HOST_MEMORY and zero devices.  See ../docs/report/README.md T3.2.

The criterion
-------------
A name is a trap when the same libc defines it at two or more versions whose
st_value DIFFERS.  Same address at several versions is just re-versioning (the
glibc 2.34 libpthread merge does this to a few hundred symbols) and is harmless
-- one implementation, several labels, any of them is correct.

Usage
-----
    python3 tools/version_traps.py /lib/x86_64-linux-gnu/libc.so.6
    python3 tools/version_traps.py <libc...> --json traps.json
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elfsym import Elf  # noqa: E402


class NoVersionInfo(Exception):
    """The file carries no symbol versioning, so it can have no traps.

    Distinguished from "no traps found" on purpose: musl legitimately has none,
    and a --check against something that is not a versioned libc would
    otherwise report a clean pass having examined nothing.
    """


def traps_for(path):
    """{name: {'default': ver|None, 'others': [...], 'addrs': {ver: addr}}}"""
    e = Elf(path)
    vs = e.versym()
    if vs is None:
        raise NoVersionInfo(path)
    vdi = e.verdef_index()

    by_name = {}
    for s in e.symbols():
        if s["shndx"] == 0 or s["bind"] not in ("GLOBAL", "WEAK") or s["vis"] != 0:
            continue
        if s["idx"] >= len(vs):
            continue
        raw = vs[s["idx"]]
        ndx, hidden = raw & 0x7FFF, bool(raw & 0x8000)
        ver = vdi.get(ndx)
        if ver is None or ndx <= 1:
            continue                      # unversioned definition, nothing to pick
        by_name.setdefault(s["name"], []).append((ver, hidden, s["value"]))

    traps, benign = {}, {}
    for name, entries in by_name.items():
        if len(entries) < 2:
            continue
        addrs = {v: a for v, _, a in entries}
        default = next((v for v, h, _ in entries if not h), None)
        rec = {
            "default": default,
            "others": sorted(v for v, h, _ in entries if h),
            "addrs": {v: hex(a) for v, a in addrs.items()},
        }
        if len(set(addrs.values())) > 1:
            traps[name] = rec
        else:
            benign[name] = rec
    return traps, benign


# `VC_EXCLUDED <symbol> <reason>`, one per line, inside a comment. Anchored so
# the phrase appearing in prose elsewhere in the file is not mistaken for an
# entry.
_EXCL_RE = re.compile(r"^\*?\s*VC_EXCLUDED\s+([A-Za-z_][A-Za-z0-9_]*)\s+(\S.*)$")


def read_coverage(path):
    """(covered, excluded) as declared by src/version-compat.c itself.

    Covered   = every `VC_SLOT(name)`, which is the macro that gives a
                forwarder its resolved-target slot. One per forwarder, so it
                cannot drift from the definitions around it.
    Excluded  = every `VC_EXCLUDED name` in the comment block, each of which
                carries its reason on the same line.
    """
    covered, excluded = set(), {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s.startswith("VC_SLOT(") and s.endswith(")"):
                covered.add(s[len("VC_SLOT("):-1].strip())
            else:
                m = _EXCL_RE.match(s)
                if m:
                    excluded[m.group(1)] = m.group(2).strip()
    return covered, excluded


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("libc", nargs="+", help="libc.so.6 (or any versioned provider)")
    ap.add_argument("--json", help="write the merged trap set here")
    ap.add_argument("--check", metavar="version-compat.c",
                    help="fail if this libc has a trap that file neither "
                         "forwards nor explicitly excludes")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    merged = {}
    examined = 0
    for p in args.libc:
        if not os.path.exists(p):
            print(f"error: no such file: {p}", file=sys.stderr)
            return 2
        try:
            traps, benign = traps_for(p)
        except AssertionError as exc:
            # elfsym asserts on anything that is not an ELF64 object. Pointing
            # this at a source file or a script should say so, not produce a
            # traceback that looks like a bug in the audit.
            print(f"error: {exc}", file=sys.stderr)
            return 2
        except NoVersionInfo:
            # Not a failure by itself: musl has no symbol versions and so no
            # traps. Say which file, so a --check that passes says what it
            # passed on.
            print(f"== {p}")
            print("   no symbol versioning in this file, so no traps")
            continue
        examined += 1
        if not args.quiet:
            print(f"== {p}")
            print(f"   multi-version, SAME address (harmless re-versioning): {len(benign)}")
            print(f"   multi-version, DIFFERENT address (traps)           : {len(traps)}")
            for n in sorted(traps):
                t = traps[n]
                print(f"     {n:<34} default={t['default'] or '(none)':<14} "
                      f"others={','.join(t['others'])}")
        for n, t in traps.items():
            # A symbol with no default definition cannot be forwarded; record it
            # so the generator can refuse loudly instead of emitting a stub that
            # resolves to NULL.
            prev = merged.get(n)
            if prev is None or (prev.get("default") is None and t.get("default")):
                merged[n] = t

    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"traps": merged}, f, indent=2, sort_keys=True)
            f.write("\n")
        if not args.quiet:
            print(f"\nwrote {args.json}: {len(merged)} trap(s)")

    if args.check:
        if examined == 0:
            print("\nFAIL: nothing with symbol versioning was examined, so this "
                  "check proves nothing.\n      Point --check at a versioned libc.",
                  file=sys.stderr)
            return 2
        covered, excluded = read_coverage(args.check)
        if not covered and not excluded:
            print(f"\nFAIL: {args.check} declares no VC_SLOT and no VC_EXCLUDED. "
                  "Either it is the\n      wrong file, or the macro was renamed "
                  "and this audit has been passing on nothing.",
                  file=sys.stderr)
            return 2
        uncovered = sorted(set(merged) - covered - set(excluded))
        # A forwarder for something this libc does not consider a trap is not an
        # error, because an older glibc has fewer traps than the newest one, and the
        # extra forwarder is a correct no-op there. Report it, do not fail.
        extra = sorted(covered - set(merged))
        print()
        print(f"audit: {len(merged)} trap(s) in this libc, "
              f"{len(covered)} forwarded, {len(excluded)} excluded by name")
        if extra:
            print("  forwarded but not a trap in THIS libc (fine, newer glibc "
                  "has more): " + ", ".join(extra))
        for name in sorted(excluded):
            if name in merged:
                print(f"  excluded: {name:<12} {excluded[name]}")
        if uncovered:
            print()
            print("FAIL: this libc has traps version-compat.c does not handle.")
            print("      Each one is a symbol an unversioned reference can bind")
            print("      to the wrong definition of. Add a forwarder, or add a")
            print("      `VC_EXCLUDED <name> <reason>` line saying why not.")
            for n in uncovered:
                t = merged[n]
                print(f"        {n:<30} default={t['default'] or '(none)'} "
                      f"others={','.join(t['others'])}")
            return 1
        print("ok: every trap in this libc is forwarded or explicitly excluded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
