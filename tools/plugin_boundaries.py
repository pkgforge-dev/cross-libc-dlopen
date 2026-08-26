#!/usr/bin/env python3
"""Enumerate every bundled object that loads a HOST plugin, and say which of
those boundaries this repository has actually measured.

WHY THIS EXISTS. The OpenGL gap sat in the README for a whole session labelled
"host packaging, not libc" and nobody looked again, because finding it required
someone to WONDER whether libglvnd was a loader. It is, and so are several
other things in the same AppDir. That question should not depend on anybody
wondering: a bundled object that imports dlopen is a loader by construction,
and the set of them is a property of the bundle that can be read off it.

The failure mode this catches is not a libc mismatch. It is:

    the bundle ships a LOADER, the loader wants a PLUGIN in a particular
    shape, and the host has the capability but not that shape.

cross-libc-dlopen.so fixes the first kind of gap -- the plugin exists and is
nameable but was built against another libc. It cannot fix the second: on a
classic-Mesa host there is no libGLX_mesa.so.0 to carry across at all. That
needs the bundled loader replaced (src/gl-fwd.c), which is a different repair,
so the two gaps are named separately in the output.

The verdicts are covered / unmeasured / n/a. `unmeasured` is deliberately not
folded into either of the others: a boundary that has been described and never
run is exactly what the OpenGL one was for a whole session, and the word for
that state has to exist or the state becomes invisible again.

    tools/plugin_boundaries.py <AppDir>            report
    tools/plugin_boundaries.py <AppDir> --check    exit 1 on an unclassified
                                                   loader (the regression gate)
"""
import argparse, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elfsym import Elf

# Everything already understood, and what the understanding is. A loader that
# is NOT in this table is the point of the whole tool: it is a boundary nobody
# has looked at, and --check fails on it.
#
#   covered      a case in the suite measures this boundary and it works
#   unmeasured   identified and described, and nobody has run it. NOT the same
#                as covered: the OpenGL gap spent a whole session looking like
#                the first while being the second
#   n/a          imports dlopen for something that is not a host-plugin
#                boundary at all
KNOWN = {
    'libvulkan.so.1':    ('covered', 'ICD from /usr/share/vulkan/icd.d/*.json; '
                                     'cross-libc-dlopen carries it across the libc gap (E30-E37)'),
    # Note which of these two actually turns up. glvnd's libGL.so.1 imports no
    # dlopen at all, because it is a re-export layer, and libGLX.so.0 is what opens
    # the vendor library. A human enumerating this by hand writes down
    # libGL.so.1, because that is the name in the failure message. The entry
    # below is kept for an AppDir that bundles a CLASSIC Mesa libGL, which does
    # dlopen its own DRI driver.
    'libGL.so.1':        ('covered', 'a libGL that loads something itself: classic Mesa opens '
                                     'its DRI driver from /usr/lib/dri. src/gl-fwd.c stands in '
                                     'for the bundled one either way (E61-E64)'),
    'libGLX.so.0':       ('covered', "glvnd's vendor dlopen: libGLX_<vendor>.so.0, which a "
                                     'classic-Mesa host does not ship at all. src/gl-fwd.c '
                                     'replaces the dispatcher rather than supplying it '
                                     '(E61-E64)'),
    'libEGL.so.1':       ('covered', 'glvnd EGL dispatcher -> /usr/share/glvnd/egl_vendor.d '
                                     '-> libEGL_<vendor>.so.0; src/gl-fwd.c built as '
                                     'egl-fwd.so replaces it (E65, E66)'),
    'libGLdispatch.so.0':('n/a',     'glvnd internal dispatch table, loads no host plugin'),
    'libwayland-client.so.0': ('n/a', 'dlopens nothing on the host; libffi is bundled'),
    'libffi.so.8':       ('n/a',     'no host plugin'),
    'libX11.so.6':       ('unmeasured', 'loadable i18n modules under /usr/lib/X11/locale, on a '
                                        'build that has them. The other host paths it carries '
                                        '-- XErrorDB, XKeysymDB, Compose -- are DATA, not code, '
                                        'and are not this kind of boundary'),
    'libxcb.so.1':       ('n/a',     'no host plugin'),
    'libdrm.so.2':       ('n/a',     'opens device nodes, not plugins'),
    'libstdc++.so.6':    ('n/a',     'dlopen only for the unwinder fallback'),
    'libgcc_s.so.1':     ('n/a',     'no host plugin'),
    'libc.so.6':         ('n/a',     'NSS and gconv, which the bundle carries itself'),
    'libpthread.so.0':   ('n/a',     'no host plugin'),
    'libdl.so.2':        ('n/a',     'it IS dlopen'),
    'libm.so.6':         ('n/a',     'no host plugin'),
    'libnss_files.so.2': ('n/a',     'no host plugin'),
    # None of these is bundled by the demo AppDir, so nothing here has run them.
    # They are listed anyway: an AppImage that DOES bundle one is classified on
    # sight rather than investigated from scratch, and each is the shape the
    # OpenGL boundary was: a bundled loader wanting a host plugin.
    'libasound.so.2':    ('unmeasured', 'ALSA plugins from /usr/lib/alsa-lib'),
    'libpulse.so.0':     ('unmeasured', 'PulseAudio modules'),
    'libva.so.2':        ('unmeasured', 'VA-API driver <name>_drv_video.so from /usr/lib/dri'),
    'libvdpau.so.1':     ('unmeasured', 'libvdpau_<driver>.so.1'),
    'libOpenCL.so.1':    ('unmeasured', 'the ICD list in /etc/OpenCL/vendors'),
    'libgbm.so.1':       ('unmeasured', 'GBM backend from /usr/lib/gbm'),
    # Found BY this tool rather than by anyone thinking of it, which is the
    # whole argument for having it. It is libdecor-rs, a Rust reimplementation
    # with the decoration plugins linked in, so it has no plugin directory:
    # the only dlopen is a lazy one for the BUNDLED libwayland-client.so.0.
    # It does read host fonts through FONTCONFIG_PATH, which is data, not code.
    'libdecor-0.so.0':   ('n/a',     'libdecor-rs: decorations are linked in, the one dlopen '
                                     'is the bundled libwayland-client.so.0'),
    'vkcube':            ('n/a',     'dlopens the BUNDLED libvulkan/libX11/libxcb/libwayland '
                                     'rather than linking them; no host plugin'),
    'vkmark':            ('n/a',     'same shape as vkcube'),
    'eglgears_x11':      ('n/a',     'same shape as vkcube'),
    'eglgears_wayland':  ('n/a',     'same shape as vkcube'),
    'glxgears':          ('n/a',     'no host plugin'),
}

# Strings that name a plugin or a place plugins are looked for. Deliberately
# loose: a false positive costs one line of output, a false negative costs a
# session.
PLUGINISH = re.compile(
    rb'(?:/(?:usr/)?(?:lib|lib64|share|etc)[a-zA-Z0-9_./+-]*'
    rb'|lib[a-zA-Z0-9_+-]*\.so(?:\.[0-9]+)*'
    rb'|[a-zA-Z0-9_]+_drv_video\.so'
    rb'|[A-Z][A-Z0-9_]*(?:_PATH|_DIR|_DRIVER|_VENDOR_LIBRARY_NAME|_ICD_FILENAMES|_DRIVER_FILES))')


def strings_of(elf):
    """Printable candidates from the read-only data sections."""
    out = set()
    for sh in elf.shdrs:
        # SHT_PROGBITS, allocated, not writable, not executable: .rodata and friends
        if sh['type'] != 1 or not (sh['addr']):
            continue
        blob = elf.d[sh['off']:sh['off'] + sh['size']]
        for m in PLUGINISH.finditer(blob):
            s = m.group(0).decode('ascii', 'replace')
            if len(s) > 3:
                out.add(s)
    return out


def scan(appdir):
    roots = [os.path.join(appdir, 'lib'), os.path.join(appdir, 'shared', 'lib'),
             os.path.join(appdir, 'bin'), os.path.join(appdir, 'shared', 'bin')]
    seen, found = set(), []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                e = Elf(path)
            except Exception:
                continue
            key = e.soname() or name
            if key in seen:
                continue
            imports = e.imports()
            if not ({'dlopen', 'dlmopen'} & imports):
                continue
            seen.add(key)
            found.append((key, path, sorted(strings_of(e))))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('appdir')
    ap.add_argument('--check', action='store_true',
                    help='exit 1 if any loader is not in the known table')
    ap.add_argument('--verbose', action='store_true',
                    help='print the plugin-ish strings behind each verdict')
    args = ap.parse_args()

    found = scan(args.appdir)
    if not found:
        print(f'{args.appdir}: no bundled object imports dlopen. '
              f'Either the path is wrong or the bundle loads nothing.')
        return 1

    unknown, unmeasured = [], []
    print(f'{len(found)} bundled objects import dlopen. Each is a loader, and a '
          f'loader is a boundary:\n')
    for key, path, strs in found:
        verdict, why = KNOWN.get(key, ('UNCLASSIFIED',
                                       'nobody has looked at what this loads'))
        if verdict == 'UNCLASSIFIED':
            unknown.append(key)
        elif verdict == 'unmeasured':
            unmeasured.append(key)
        print(f'  {verdict:<13} {key}')
        print(f'                {why}')
        if args.verbose and strs:
            for s in strs[:12]:
                print(f'                  . {s}')
        print()

    print(f'covered {sum(1 for k, _, _ in found if KNOWN.get(k, ("",))[0] == "covered")}'
          f'   n/a {sum(1 for k, _, _ in found if KNOWN.get(k, ("",))[0] == "n/a")}'
          f'   unmeasured {len(unmeasured)}   UNCLASSIFIED {len(unknown)}')
    if unmeasured:
        print('\nThe unmeasured ones are the shape the OpenGL boundary was, and '
              'none of them is a libc problem. Named, not fixed: ../docs/report/09-the-second-boundary.md 9.10.')
    if unknown:
        print('\nUNCLASSIFIED: ' + ', '.join(unknown))
        print('Add each to KNOWN in this file once you have measured what it '
              'loads from the host. That is the whole point: a loader nobody '
              'has looked at is exactly how the OpenGL gap survived a session.')
        return 1 if args.check else 0
    return 0


if __name__ == '__main__':
    sys.exit(main())
