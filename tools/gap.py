#!/usr/bin/env python3
"""
Measure the cross-libc symbol gap: which symbols does a musl-built library
closure import that glibc cannot provide?

Self-contained: no third-party modules, no readelf, no dpkg, no Linux.
Run `python3 tools/gap.py --fetch` once to download the artifacts, then `python3 gap.py`.

Reproduces the musl-gap measurement in ../docs/report/README.md.
"""
import glob
import io
import lzma
import os
import sys
import tarfile
import urllib.request

from elfsym import Elf

ALPINE = "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64"
APKS = [
    "mesa-vulkan-swrast-25.1.9-r0",
    "mesa-25.1.9-r0",
    "mesa-gl-25.1.9-r0",
    "musl-1.2.5-r12",
    "libgcc-14.2.0-r6",
    "libstdc++-14.2.0-r6",
    "llvm20-libs-20.1.8-r0",
]
DEB_URL = ("http://deb.debian.org/debian/pool/main/g/glibc/"
           "libc6_2.41-12+deb13u4_amd64.deb")
DEB = os.path.basename(DEB_URL)

GLIBC_MEMBERS = ("libc.so", "ld-linux", "libm.so", "libpthread", "libdl.so", "librt.so")


def get(url, dest):
    if os.path.exists(dest):
        return
    print(f"  fetching {os.path.basename(dest)} ...", flush=True)
    urllib.request.urlretrieve(url, dest)


def fetch():
    print("Fetching Alpine (musl) artifacts:")
    for p in APKS:
        get(f"{ALPINE}/{p}.apk", f"{p}.apk")
        d = os.path.join("x", p)
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
            # .apk is a (multi-stream) gzipped tar; ignore the signature stream.
            try:
                tarfile.open(f"{p}.apk", "r:gz").extractall(d)
            except Exception as e:
                print(f"    note: partial extract of {p}: {e}")
    print("Fetching glibc reference:")
    get(DEB_URL, DEB)
    extract_deb()


def extract_deb():
    """Pull the glibc DSOs out of a .deb: ar archive -> data.tar.xz -> files."""
    if glob.glob("glibc/libc.so*"):
        return
    d = open(DEB, "rb").read()
    assert d[:8] == b"!<arch>\n", "not an ar archive"
    off = 8
    while off < len(d):
        hdr = d[off:off + 60]
        if len(hdr) < 60:
            break
        name = hdr[0:16].decode().strip()
        size = int(hdr[48:58].decode().strip())
        body = d[off + 60: off + 60 + size]
        if name.startswith("data.tar"):
            raw = lzma.decompress(body) if name.endswith(".xz") else body
            tf = tarfile.open(fileobj=io.BytesIO(raw))
            os.makedirs("glibc", exist_ok=True)
            for m in tf.getmembers():
                b = os.path.basename(m.name)
                if m.isfile() and b.startswith(GLIBC_MEMBERS):
                    open(os.path.join("glibc", b), "wb").write(tf.extractfile(m).read())
                    print(f"    extracted {b}")
            return
        off += 60 + size + (size % 2)
    raise SystemExit("no data.tar member found in .deb")


def flags_of(e):
    f = e.dtag(30)
    f = f[0] if f else 0
    out = []
    if f & 0x8:
        out.append("BIND_NOW")
    if f & 0x2:
        out.append("SYMBOLIC")
    if f & 0x10:
        out.append("STATIC_TLS")
    return ",".join(out)


def main():
    if "--fetch" in sys.argv:
        fetch()
    if not glob.glob("glibc/libc.so*"):
        if os.path.exists(DEB):
            extract_deb()
        else:
            raise SystemExit("missing artifacts -- run: python3 tools/gap.py --fetch")

    glibc = set()
    for p in glob.glob("glibc/*"):
        glibc |= Elf(p).exports()
    muslpath = glob.glob("x/musl-*/lib/libc.musl-x86_64.so.1")
    if not muslpath:
        raise SystemExit("missing musl libc -- run: python3 tools/gap.py --fetch")
    musl = Elf(muslpath[0]).exports()

    print(f"glibc exports : {len(glibc)}")
    print(f"musl  exports : {len(musl)}")
    print(f"musl-only (absent from glibc entirely): {len(musl - glibc)}")
    print(f"  {sorted(musl - glibc)}")
    print()

    libs = sorted({p for p in glob.glob("x/*/usr/lib/*.so*") + glob.glob("x/*/lib/*.so*")
                   if os.path.isfile(p) and os.path.getsize(p) > 1000
                   and "musl" not in os.path.basename(p)})
    print(f"{'library':42} {'imp':>5} {'musl':>5} {'GAP':>4}  flags")
    union = set()
    for l in libs:
        try:
            e = Elf(l)
        except Exception as ex:
            print(f"{os.path.basename(l):42}  parse error: {ex}")
            continue
        imp = e.imports()
        g = (imp & musl) - glibc
        union |= g
        print(f"{os.path.basename(l):42} {len(imp):5} {len(imp & musl):5} "
              f"{len(g):4}  {flags_of(e)}")
        if g:
            weak = e.weak_imports()
            for s in sorted(g):
                print(f"{'':42}   -> {s} ({'WEAK' if s in weak else 'STRONG'})")

    print()
    print(f"UNION OF GAP over whole musl closure: {sorted(union)}")
    print()
    print("Expected: ['___environ', 'atexit']")
    print("  atexit     STRONG -> fatal under DF_BIND_NOW")
    print("  ___environ WEAK   -> resolves to 0, latent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
