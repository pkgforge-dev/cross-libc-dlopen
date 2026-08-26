#!/usr/bin/env python3
"""Which version-binding traps does a given object actually step on?

`version_traps.py` answers "which symbols in this libc are traps".  That is a
property of the libc alone and says nothing about whether anything in a real
process reaches one.  This answers the other half: given an object and the libc
it will be resolved against, which of that libc's traps does this object import,
and does it import them WITH a version or without one?

Why it matters
--------------
An unversioned reference does not get the default definition; it gets glibc's
obsolete one (REPORT.md 6.2).  Three kinds of object have unversioned
references:

  * anything built against musl, which never had symbol versions,
  * anything `cross-libc-dlopen.c` has stripped, which is the point of the whole
    exercise, and
  * closed-source vendor blobs that were simply linked that way.

The third is the one nobody expects.  Measured on this machine, Microsoft's
`libdxcore.so` and `libd3d12.so` -- shipped inside NVIDIA's WSL driver package
and loaded by CUDA and by Mesa's d3d12 driver respectively -- have no
`.gnu.version_r` section at all and import six trapped names each.

Usage
-----
    python3 tools/manual/trap_users.py <libc.so.6> <object>...

Exit 0 always: this is a survey, not a gate.  `version_traps.py --check` is the
gate, and it runs against the libc rather than against its callers.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
# elfsym and version_traps live in tools/, one level up: this file is manual
# and they are not. The old form inserted this file's own directory twice,
# which was harmless while everything sat together and became an ImportError
# the moment it did not.
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.dirname(_HERE))

from elfsym import Elf                        # noqa: E402
from version_traps import traps_for, NoVersionInfo   # noqa: E402


def survey(libc, paths):
    try:
        traps, benign = traps_for(libc)
    except NoVersionInfo:
        print(f"error: {libc} has no symbol versioning, so it has no traps",
              file=sys.stderr)
        return 2
    print(f"libc {libc}: {len(traps)} trap(s), "
          f"{len(benign)} benign re-versioning(s)")

    for path in paths:
        e = Elf(path)
        versioned = bool(e.verneed())
        # imports() and weak_imports() give the plain names; an object WITH
        # version information still imports the same names, so the set to
        # intersect is the same either way. What changes is whether the
        # reference carries a version, and that is the whole question.
        names = {n.split("@")[0] for n in
                 set(e.imports()) | set(e.weak_imports())}
        hit = sorted(names & set(traps))
        print(f"\n== {os.path.basename(path)}")
        print(f"   imports              : {len(names)}")
        print(f"   trapped names among them: {len(hit)}")
        if versioned:
            print("   symbol versioning    : PRESENT, so every one of those "
                  "references names the version\n"
                  "                          it wants and none of them is a "
                  "trap for this object")
        else:
            print("   symbol versioning    : ABSENT, so every one of those "
                  "references is unversioned\n"
                  "                          and binds the OBSOLETE definition")
        for n in hit:
            t = traps[n]
            print(f"     {n:<26} default={t['default'] or '(none)':<12} "
                  f"obsolete={','.join(t['others'])}")
    return 0


def main():
    if len(sys.argv) < 3:
        print("usage: trap_users.py <libc.so.6> <object>...", file=sys.stderr)
        return 2
    for p in sys.argv[1:]:
        if not os.path.exists(p):
            print(f"error: no such file: {p}", file=sys.stderr)
            return 2
    return survey(sys.argv[1], sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
