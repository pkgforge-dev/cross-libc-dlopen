# Traps when you are USING this

Each of these cost somebody real time once. The much longer list of traps that
apply to working *on* this repository is in [`docs/history/traps.md`](history/traps.md);
this page is only the ones a consumer hits.

---

### `ld.so --preload A --preload B` silently keeps only B

glibc's option parser holds a single `preloadarg`, so the second flag replaces
the first. The command line reads as if both are loaded, and nothing warns.

```bash
ld.so --preload "A B" ...
```

One flag, space-separated. That is the working form.

---

### Preload constructors run in REVERSE of the list

Listing a shim *after* another runs its constructor *first*. This is why the GL
shims **ask** for the loader rather than depending on ordering, and why the
order in `.preload` does not matter. See [`integrating.md`](integrating.md).

---

### Shell scripts must be LF

A CR turns a shell script into a `$'...\r'` "not found" error that names the
wrong thing entirely. On a repository this is `.gitattributes`' job; on your own
launcher script it is yours. It reads like a missing binary and it is a line
ending.

---

### `timeout` on a program that never exits hangs a `$( )` capture

...**on the case that WORKED.** `glxgears` does not exit; the timeout kills the
wrapper and leaves the children holding the stdout pipe. The case that *fails*
exits immediately and looks fine, so the symptom is exactly inverted from the
fault. Write to a file and reap.

---

### A test whose success condition is "a renderer string appeared" passes a broken shim

`GL_RENDERER` printing does not mean anything was drawn. The probes in
[`tests/`](../tests/) clear to a known colour and read the pixel back for
precisely this reason. Keep that property in anything you write to check this.

---

### A driver reachable only through `/etc/ld.so.cache` is invisible

A bundled loader is typically patched to skip the host's cache, so a library
whose directory is named *only* there is unreachable however correct everything
else is. The symptom is a load failure naming a dependency, several levels down
from the driver you were trying to open. Extend the library path. For sharun,
that is `SHARUN_FALLBACK_LIBRARY_PATH`.

---

### A bundle that ships its own vendor library must keep it

Forwarding to the host's because "the host has none" puts two Mesas in one
process. This was found by running a real GTK4 application, not by reasoning
about it.

---

### `couldn't get an RGB, Double-buffered visual` is not about visuals

Or about libc. It is the message a glvnd dispatcher gives when the host ships no
vendor library for it to dispatch to. [`overview.md`](overview.md) is the whole
of that story and [`diagnostics.md`](diagnostics.md) is the ladder for finding
which layer you are actually on.
