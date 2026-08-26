#!/usr/bin/env python3
"""
Build a symbol inventory for a libc runtime set, and diff two of them.

One runtime set = one directory holding ld-linux/libc/libm and (where the
release still ships them) the legacy split libraries.  For each set this
records every dynamically exported symbol together with the LOWEST GLIBC_x.y
version that defines it -- the version floor a consumer must clear.

Used three ways:
  * ../docs/report/README.md A4 -- what does the *actual bundled* runtime provide
  * ../docs/report/README.md A6 -- newer/older/complete, per distro, for the Design R matrix
  * ../docs/report/README.md B2 -- the generator's input: symbols a newer glibc has and
                    an older one does not

No third-party modules; ELF parsing comes from elfsym.py beside this file.

    python3 tools/libc_inventory.py scan   <dir> [--name TAG]      -> JSON
    python3 tools/libc_inventory.py diff   <old.json> <new.json>
    python3 tools/libc_inventory.py matrix <dir-of-dirs>
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elfsym import Elf  # noqa: E402

# The runtime set Design R must switch as a WHOLE (E11: a mixed set segfaults).
# Order matters only for reporting.
RUNTIME_SET = [
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libutil.so.1",
    "libanl.so.1",
    "libresolv.so.2",
]
MUSL_SET = ["ld-musl-x86_64.so.1", "libc.musl-x86_64.so.1"]

_VER_RE = re.compile(r"^GLIBC_(\d+)\.(\d+)(?:\.(\d+))?$")


def version_key(v):
    """Sort key for a GLIBC_x.y[.z] version name. Non-matching sorts first."""
    m = _VER_RE.match(v or "")
    if not m:
        return (0, 0, 0)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3) or 0))


def release_key(v):
    """Sort key for a bare '2.41' release string."""
    parts = (v or "0").split(".")
    try:
        return tuple(int(p) for p in parts[:3]) + (0,) * (3 - len(parts[:3]))
    except ValueError:
        return (0, 0, 0)


SHN_ABS = 0xFFF1
STT_NAMES = {0: "NOTYPE", 1: "OBJECT", 2: "FUNC", 6: "TLS", 10: "IFUNC"}


def symbol_versions(path):
    """
    {symbol: (lowest GLIBC_x.y defining it, type, size, is_abs)} for one DSO.

    glibc encodes per-symbol versions in .gnu.version_d + .gnu.version.  A
    symbol defined at several versions (compat symbols) appears several times
    in .dynsym; the LOWEST version is the floor a consumer needs, so that is
    what is kept.  Where a file carries no version table at all every symbol
    maps to None -- still a valid "this symbol exists" answer.

    Type and size come along because a shim generator must not emit a
    function where the real symbol is a data object.  is_abs flags SHN_ABS
    entries: glibc puts its version *names* (GLIBC_2.32, GLIBC_ABI_DT_RELR)
    in .dynsym as zero-sized SHN_ABS objects.  They are ABI markers, not API,
    and shimming one would emit a C identifier containing a '.'.
    """
    e = Elf(path)
    verdef_idx = _verdef_index(e)
    versym = _versym_array(e)

    out = {}
    symo, n, stro = e._dynsym_span()
    import struct
    for i in range(n):
        st_name, st_info, st_other, st_shndx, _, st_size = struct.unpack_from(
            "<IBBHQQ", e.d, symo + i * 24)
        if st_name == 0 or st_shndx == 0:
            continue                      # unnamed, or an import
        if (st_info >> 4) not in (1, 2):  # GLOBAL / WEAK only
            continue
        if (st_other & 3) != 0:           # not default visibility
            continue
        name = e._cstr(stro, st_name)
        ver = None
        if versym is not None and i < len(versym):
            ver = verdef_idx.get(versym[i] & 0x7FFF)
        rec = (ver, STT_NAMES.get(st_info & 0xF, "?"), int(st_size),
               st_shndx == SHN_ABS)
        prev = out.get(name)
        if prev is None:
            out[name] = rec
        elif ver is not None and (prev[0] is None or version_key(ver) < version_key(prev[0])):
            out[name] = rec
    return out


def _verdef_index(e):
    """{version index -> version name} from DT_VERDEF."""
    import struct
    vd = e.dtag(0x6FFFFFFC)
    if not vd:
        return {}
    base = e.v2o(vd[0])
    stro = e.v2o(e.dtag(5)[0])
    if base is None or stro is None:
        return {}
    num = e.dtag(0x6FFFFFFD)
    out = {}
    pos = 0
    for _ in range(num[0] if num else 512):
        ver, flags, ndx, cnt, _h, aux, nxt = struct.unpack_from("<HHHHIII", e.d, base + pos)
        if ver != 1:
            break
        nm, = struct.unpack_from("<I", e.d, base + pos + aux)
        out[ndx & 0x7FFF] = e._cstr(stro, nm)
        if not nxt:
            break
        pos += nxt
    return out


def _versym_array(e):
    """The DT_VERSYM half-word array, or None when the file has no versions."""
    import struct
    vs = e.dtag(0x6FFFFFF0)
    if not vs:
        return None
    off = e.v2o(vs[0])
    if off is None:
        return None
    try:
        _symo, n, _stro = e._dynsym_span()
    except RuntimeError:
        return None
    if off + n * 2 > len(e.d):
        return None
    return struct.unpack_from(f"<{n}H", e.d, off)


def scan(directory, name=None):
    """Inventory one runtime-set directory."""
    members = {}
    family = "unknown"
    for f in RUNTIME_SET + MUSL_SET:
        p = os.path.join(directory, f)
        if not os.path.exists(p):
            continue
        if f in MUSL_SET:
            family = "musl"
        elif family == "unknown":
            family = "glibc"
        try:
            members[f] = symbol_versions(p)
        except Exception as ex:                       # noqa: BLE001
            members[f] = {}
            print(f"  warn: {f}: {ex}", file=sys.stderr)

    records = {}
    for f, syms in members.items():
        for s, rec in syms.items():
            prev = records.get(s)
            if prev is None:
                records[s] = rec
            elif rec[0] is not None and (prev[0] is None or
                                         version_key(rec[0]) < version_key(prev[0])):
                records[s] = rec

    symbols = {s: r[0] for s, r in records.items()}
    kinds = {s: {"type": r[1], "size": r[2], "abs": r[3]}
             for s, r in records.items()}

    # Release version: the highest GLIBC_x.y any member DEFINES.  More reliable
    # than parsing --version output and works on a bare directory of files.
    allver = [v for v in symbols.values() if v and _VER_RE.match(v)]
    release = None
    if allver:
        top = max(allver, key=version_key)
        m = _VER_RE.match(top)
        release = f"{m.group(1)}.{m.group(2)}"

    meta = {}
    mp = os.path.join(directory, "meta.txt")
    if os.path.exists(mp):
        for line in open(mp, encoding="utf-8", errors="replace"):
            if "=" in line:
                k, _, v = line.strip().partition("=")
                meta.setdefault(k, []).append(v)

    if family == "musl" and meta.get("version"):
        release = meta["version"][0]

    return {
        "name": name or os.path.basename(directory.rstrip("/\\")),
        "family": family,
        "release": release,
        "members": sorted(members),
        "missing": [f for f in (MUSL_SET if family == "musl" else RUNTIME_SET)
                    if f not in members],
        "counts": {f: len(s) for f, s in sorted(members.items())},
        "symbols": symbols,
        "kinds": kinds,
        "meta": {k: v for k, v in meta.items() if k != "have"},
    }


def diff(old, new):
    """Symbols `new` exports that `old` does not export at all."""
    gained = sorted(set(new["symbols"]) - set(old["symbols"]))
    # Symbols both have, but where new requires a version old never defined.
    raised = []
    for s in sorted(set(new["symbols"]) & set(old["symbols"])):
        nv, ov = new["symbols"][s], old["symbols"][s]
        if nv and ov and version_key(nv) > version_key(ov):
            raised.append((s, ov, nv))
    return gained, raised


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan")
    s.add_argument("dir")
    s.add_argument("--name")
    s.add_argument("-o", "--out")

    d = sub.add_parser("diff")
    d.add_argument("old")
    d.add_argument("new")

    m = sub.add_parser("matrix")
    m.add_argument("root")
    m.add_argument("-o", "--out")

    a = ap.parse_args()

    if a.cmd == "scan":
        inv = scan(a.dir, a.name)
        js = json.dumps(inv, indent=1, sort_keys=True)
        if a.out:
            open(a.out, "w", encoding="utf-8").write(js)
            print(f"{inv['name']}: family={inv['family']} release={inv['release']} "
                  f"symbols={len(inv['symbols'])} -> {a.out}")
        else:
            print(js)
        return 0

    if a.cmd == "diff":
        old = json.load(open(a.old, encoding="utf-8"))
        new = json.load(open(a.new, encoding="utf-8"))
        gained, raised = diff(old, new)
        print(f"{old['name']} ({old['release']}) -> {new['name']} ({new['release']})")
        print(f"  symbols only in {new['name']}: {len(gained)}")
        print(f"  version floor raised         : {len(raised)}")
        for sym in gained:
            print(f"    + {sym} @ {new['symbols'][sym]}")
        return 0

    if a.cmd == "matrix":
        rows = []
        for name in sorted(os.listdir(a.root)):
            p = os.path.join(a.root, name)
            if os.path.isdir(p):
                rows.append(scan(p, name))
        out = {r["name"]: r for r in rows}
        if a.out:
            open(a.out, "w", encoding="utf-8").write(json.dumps(out, indent=1, sort_keys=True))
        print(f"{'set':18} {'family':7} {'release':8} {'syms':>6}  missing")
        for r in sorted(rows, key=lambda r: (r["family"], release_key(r["release"]))):
            print(f"{r['name']:18} {r['family']:7} {str(r['release']):8} "
                  f"{len(r['symbols']):6}  {','.join(r['missing']) or '-'}")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
