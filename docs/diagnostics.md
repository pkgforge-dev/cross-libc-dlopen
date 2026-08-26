# It did not work. Which layer?

A rung-by-rung procedure. Start at the top and stop at the first rung that
answers wrong -- that is the layer, and the rungs below it are noise until
it is fixed.

## 6. Diagnostic ladder

When something fails, report **which rung caught it**.

0. **Is this even the libc gap?** Before anything else, ask whether the host has
   the plugin AT ALL in the shape the bundled loader wants. `couldn't get an
   RGB, Double-buffered visual` from a GL app on a musl host is not a libc
   failure and no amount of rung 3 through 11 will find anything: the host's
   Mesa is classic, there is no `libGLX_<vendor>.so.0`, and the answer is
   `gl-fwd.so` rather than `cross-libc-dlopen.so`.
   `python3 tools/plugin_boundaries.py $APPDIR --verbose` lists every bundled
   loader and what it looks for; `ls /usr/lib/libGLX_*.so.0
   /usr/lib/*/libGLX_*.so.0` answers it for GL in one command.

   ⚠ **With the shim loaded, `CROSS_LIBC_DLOPEN_DEBUG=1` says nothing until the
   first GL CALL**, because that is when the host stack loads. Read the lines
   in this order:

   - `N entry points, none resolved yet` -- the shim is present and the
     program has not called GL yet. On a Vulkan-only run this is the LAST line
     you will see and it is correct (E74).
   - `target <path> -- <why>` -- which library it chose, and whether the reason
     was the bundle's own vendor library, the host's, or neither.
   - `N of M entry points resolved` -- how much of the dispatcher this host can
     stand behind.
   - `no target; all M entry points return zero` -- it found NOTHING, and every
     GL call in the process is returning zero. This replaces what used to
     appear as `0 of M`; that line is now only printed when a target loaded and
     provided none of the names, which says something different.
   - `ABSENT entry point called: <name>` -- the application called something
     this host does not implement. One line per name, at its first call.

   `CROSS_LIBC_DLOPEN_GL_TRACE=1` adds one line per entry point at its first call,
   which is what to reach for when the question is *what does this application
   use* rather than *what did the shim do* -- and the only form that survives
   the program being killed, which most GL programs are.
1. **Host driver sane?** `vulkaninfo --summary` natively. If this fails, stop.
2. **Display, not libc?** Re-run under
   `xvfb-run -a -s '-screen 0 1024x768x24 +extension GLX +render'`. WSI errors
   are not this project's bug.
3. **Feature on?** `CROSS_LIBC_DLOPEN_DEBUG=1`. No ` [cross-libc-dlopen.so] >> ` lines
   means the marker, the env switch, or the `.preload` order is wrong. No
   `cross-libc-dlopen: rewriting` line and no `needs no rewrite` line means the path was
   not absolute and nothing was ever intercepted.
4. **Which object, which symbol?** `CROSS_LIBC_DLOPEN_DRYRUN=1`, or
   `LD_DEBUG=libs,bindings`. An `undefined symbol: X` names the next candidate.
5. **Is the library findable at all?** The failure most likely to send you the
   wrong way. A driver that `dlopen`s the rest of its own stack by BARE SONAME
   -- `libdxcore.so` from CUDA, `libd3d12.so` from Mesa's d3d12 -- is not
   intercepted, so `ld.so` searches `--library-path` and nothing else, because
   the cache is inhibited. What you see when it misses is
   `CUDA_ERROR_NO_DEVICE` or `glXCreateContext failed`, neither of which
   mentions a library. `LD_DEBUG=libs LD_DEBUG_OUTPUT=/tmp/ld` then
   `grep 'find library=' /tmp/ld.*` is what settles it in one command.
7. **Is `X` really absent?** Check with `tools/elfsym.py` against the **bundled**
   `libc.so.6`. If present, this is a scope or visibility problem, not
   availability, and needs a different fix.
6. **Is `X` merely re-homed?** musl folds `libm`, `libpthread`, `libdl`, `librt`
   and the resolver into `libc`; glibc splits them out, and glibc 2.34 merged its
   own split libraries back in. Load the library instead of shimming the symbol.
   `cld_global_scope_libs[]` in `src/cross-libc-dlopen.c` is the list.
8. **Did the rewrite corrupt the image?** Re-parse
   `$XDG_RUNTIME_DIR/.cross-libc-dlopen-*.so` with `tools/elfsym.py`.
9. **Did it need rewriting at all?** `CROSS_LIBC_DLOPEN_DEBUG=1` prints
   `provider <file> -> ...` for each `DT_VERNEED` file and says which version it
   could not vouch for. On a host older than the bundle the answer should be
   "nothing was rewritten" (E39).
10. **Loads, but the wrong definition?** `CROSS_LIBC_DLOPEN_NOSTRIP=1` keeps
    the version tags while still loading from the private copy, which separates
    "the rewrite broke it" from "the path broke it". If NOSTRIP fixes it, you
    are looking at a version-binding trap: run `tools/version_traps.py` against
    the libc and check the symbol is covered by `version-compat.c`. To read the
    answer rather than infer it, `LD_BIND_NOW=1 tests/bindprobe <lib> <symbol>`
    walks each loaded object's relocations and names the file and version behind
    the address the loader actually stored. `LD_DEBUG=bindings` cannot do this:
    it prints the version a reference ASKED for, and for this trap the whole
    point is that the reference asks for nothing.
11. **Loads and still misbehaves?** ABI territory. `tests/abi-host.c` against a
    guest built by the other libc covers the allocator, `errno`, `FILE*`,
    mutexes, condition variables and the divergent structs (E47-E50); if a
    crossing there is red, that is your answer. If they all pass, the remaining
    shapes are the two live hazards in 4.2 -- a musl-built object reading back a
    glibc-filled struct at its own stride, or comparing against its own `FTW_*`.
    Otherwise bisect with gdb: breakpoint the failing library call, `finish`,
    read the return value, and `info symbol $pc` at entry -- that last step is
    what found the version trap.
