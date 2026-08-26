## 5. Design B: the generated shim

`tools/gen_forward_shim.py`. The **selection** is generated; the
**implementations** come from an audited table. A generator that invented
semantics would be worse than the treadmill it replaces, not better. Solo splits
it the same way.

### 5.1 The floor, and what it means for this AppImage

The shipped `src/forward-shim.c` targets the demo AppImage's own bundled
runtime, **glibc 2.44**.

That is the headline finding of the ground-truth phase. The demo AppImage
bundles the newest released glibc, so **no distro in the matrix is newer**, the
selector correctly picks `bundled` on all of them, and the version gap is empty:

```
floor  : appdir-bundled glibc 2.44 (4287 symbols)
target : glibc-2.44             (4288 symbols)
musl   : 46 symbols musl exports and the floor does not
gap    : 47 symbols the floor lacks
   implementable    13
   stub-only        22
   irrelevant       12
```

The single non-musl gap symbol is `__libanl_version_placeholder`, an empty ABI
placeholder. **Case 1 is already solved for this artifact by bundling a
new-enough glibc.** It is not solved in general: any AppImage built on an older
distro has the gap, and this one acquires it the day glibc 2.45 ships.

So the generator is demonstrated at a realistic older floor as well. Floor 2.31,
target 2.44:

```
gap    : 628 symbols the floor lacks
   implementable   107
   stub-only       296
   irrelevant      225
```

Compiled with `-Wall -Wextra -Werror` on real glibc 2.31, with **42 documented
behaviours checked** (`tests/shim-selftest.c`, case E16), not just "it links":

```
  ok   strlcpy trunc          ok   stat matches __xstat     ok   bit_ceil(0)==1
  ok   strlcat trunc          ok   arc4random_uniform covers range
  ok   clz(0)==32             ok   _dl_find_object==-1      ok   sigabbrev_np(SIGKILL)
  ... 42 checks ...
SHIM TEST PASSED (0 failures)
```

### 5.2 What happens when an uncovered symbol appears

It fails loudly, naming the symbol, at the earliest point it can.

**At load time**, the dry-run and report path enumerates every strong undefined
symbol that neither the process nor the object's own dependency closure can
supply, and prints all of them, not just `ld.so`'s first.

**At call time**, a stub-only symbol aborts with its own name:

```
[cross-libc-dlopen] FATAL: sinpi: not implementable over this glibc
[cross-libc-dlopen] the bundled glibc 2.44 does not provide this symbol
[cross-libc-dlopen] and no implementation exists for it. Set CROSS_LIBC_DLOPEN_RUNTIME=host
[cross-libc-dlopen] to run against the host's own libc, which will have it.
```

**Why emit stubs at all.** Every Mesa object is `DF_BIND_NOW`, so `ld.so`
resolves the whole symbol table at load. One undefined symbol makes the library
unloadable even if that code path is never taken. A stub converts "cannot load
at all" into "works unless it genuinely needs this".

**Why C23 maths is stub-only, deliberately.** `sinpi`, `fmaximum_num`,
`roundeven` and the other 186 have exacting NaN, signed-zero and rounding-mode
semantics. An approximation that is subtly wrong is worse than a loud abort, and
no GPU driver calls them. This is a recorded decision, not an oversight: the
manifest carries a per-symbol reason for all 47.

### 5.3 The musl-only surface is larger than the Mesa closure suggested

`tools/gap.py` measures the union over the Mesa and LLVM closure as exactly
`['___environ', 'atexit']`, and that reproduces. But over the **whole** Alpine
`/usr/lib`, one more musl-only symbol is load-bearing:

```
cross-libc-dlopen: rewritten load failed: .../libX11.so.6.4.0: undefined symbol: issetugid
```

`issetugid` alone was blocking `libX11.so.6` and `libdbus-1.so.3`. It is
implementable exactly as musl implements it, over `getauxval(AT_SECURE)`.

The generator now takes `--musl <inventory>` and folds musl's 46 floor-absent
exports into the same enumerable gap, rather than relying on a hand-maintained
list. That is what took the corpus from 243/247 to **247/247**.

### 5.4 The `___environ` rename

Applied, and confirmed firing on the real `libLLVM.so.20.1`:

```
cross-libc-dlopen: ___environ -> __environ (st_name +1, no .dynstr write)
```

musl spells the environ pointer with three underscores, glibc with two. The
reference is a **weak** import, so it does not stop the load: it silently
resolves to 0 and the driver reads a NULL environment. Latent, and exactly the
class of bug that works until it does not.

The fix costs no string edits. `"___environ" + 1` **is** `"__environ"`, so
advancing `st_name` by one byte renames the reference. Two properties make this
total rather than merely likely, and both are checked:

- the symbol is **undefined**, so `DT_GNU_HASH`, which indexes only *defined*
  symbols from `symoffset` onward, does not cover it. No hash fixup.
- nothing is written to `.dynstr`, so tail-merging cannot bite. Tail-merging is
  real: 16 of 647 names in `libvulkan_lvp.so` are suffixes of another.

The general case, renaming to something that is not a suffix, needs an in-place
`.dynstr` write. `cld_dynstr_range_occupied()` refuses unless it can prove that
no other referenced offset (symbol name, `DT_NEEDED`, `SONAME`, `RPATH`,
`RUNPATH`, or a version-table name) falls inside the clobbered range. T0.7 tests
that it does refuse.

---

---

[REPORT index](README.md) | [previous](04-design-r-runtime-selection.md) | [next](06-goal-2-the-last-blocker.md)
