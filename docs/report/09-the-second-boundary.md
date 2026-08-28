## 9. The second boundary: a bundled dispatcher whose plugin the host lacks

Everything in sections 3 through 8 is about **one** kind of gap. The bundled
Vulkan loader `dlopen`s the host's ICD; the ICD was built against another libc;
`cross-libc-dlopen.so` carries it across. The host had the driver all along and the
only thing in the way was libc.

This section is about a gap of a different kind, which was in the README for a
whole session labelled "not fixable" and is now closed.

### 9.1 The skip that carried a verdict

None of this section would exist without
a pull request from @Samueru-sama, which arrived
from outside and pointed at a gap this repository had written off. The design
here differs from it in five ways, each measured below, but the gap and the
mechanism are its finding.

The previous report recorded case E38 like this:

```
E38  SKIPPED  no libGLX_<vendor>.so.0 on this host; its Mesa is not libglvnd,
              so the bundled libglvnd has no vendor to dlopen
```

and the README said, in the same breath:

> No loader shim can supply a file the distribution does not ship.

The **reason** was correct and measured. The **verdict** attached to it was
neither. A SKIP is a statement about the environment, that this host lacks a
capability, and it is allowed to name the missing capability. It is not
allowed to decide whether the gap is closable, because that is a claim about the
design space and needs its own evidence. Welded together, the skip stopped being
a question, and one line of untested prose kept OpenGL broken on every musl
distro for the whole of the previous session.

That is the process defect worth carrying forward, and section 9.10 is the
mechanism that makes it harder to repeat.

### 9.2 Two gaps, not one

| | what is wrong | what fixes it |
|---|---|---|
| **G1, the libc gap** | the host has the plugin, it is nameable, and it was built against a libc the bundle is not | `cross-libc-dlopen.so`: rewrite the object so its version requirements stop mattering, drop the musl libc edge, bridge the imports |
| **G2, the interface gap** | the host has the *capability* but ships nothing in the shape the bundled loader looks for | replace the bundled loader |

Vulkan only ever exhibits G1, and that is a property of its design rather than
luck: the loader/ICD boundary is thin and universal, every ICD exposes
`vk_icdGetInstanceProcAddr`, and every distribution that has Vulkan ships one.

OpenGL exhibits G2. The AppImage bundles libglvnd, which is a **dispatcher**: an
application links `libGL.so.1`, and at first use `libGLX.so.0` behind it
`dlopen`s a vendor library, `libGLX_<vendor>.so.0`. (Which of those two objects
does the opening matters, and section 9.10 is about how easy it is to name the
wrong one.) A host whose Mesa was built without glvnd, meaning every musl distro and
every pre-glvnd glibc distro such as Ubuntu 14.04 or Debian 8, ships no such
file at all. There is nothing for `cross-libc-dlopen` to carry. The user sees:

```
Error: couldn't get an RGB, Double-buffered visual
```

which is a message about visuals, for a fault that is about neither visuals nor
libc.

### 9.3 What a shim that replaces a library has to export

The repair is [`src/gl-fwd.c`](../../src/gl-fwd.c): an object built with SONAME
`libGL.so.1` and preloaded, so ld.so binds the application's `DT_NEEDED` to it
and never loads the bundled dispatcher. At the first GL call it picks a target
and every entry point forwards there, to the **bundled** dispatcher when the
bundle or the host has a vendor library for it, where it works and the shim's
job is to be invisible, and the host's classic `libGL.so.1` otherwise.

The one correctness rule is that **it must export everything the object it
replaces exports**, because anything less is `undefined symbol` for the first
application that links a name outside the list. The bundled `libGL.so.1`
(libglvnd 1.7.0, from the `__FILE__` strings it keeps, `../libglvnd-v1.7.0/src/...`,
rather than from the `.so.1.7.0` suffix, which encodes the OpenGL ABI version
and would have said the same thing for the wrong reason) exports **3470**
functions.

A hand-written subset is not a smaller version of this design, it is a different
and worse one, and the difference is invisible from the outside. The 33-symbol
column below is not a strawman: it is the shim proposed by @Samueru-sama, which
identified the mechanism correctly and forwarded exactly the set `glxgears`
imports. Measured on Alpine 3.22, same AppDir, same `.preload`, two shims:

```
33 of 3470     GL_RENDERER : llvmpipe (LLVM 20.1.8, 256 bits)
               glprobe: symbol lookup error: undefined symbol: glGetIntegerv
3470 of 3470   GL_RENDERER : llvmpipe (LLVM 20.1.8, 256 bits)
               readback rgba: 64 128 191 255 (want ~64 128 191 255)
               OK: GL is complete
```

Both print a renderer. `glxgears` renders under both, because `glxgears` imports
exactly 33 GL symbols and a shim written to make `glxgears` run passes a
`glxgears`-shaped test. That is why [`tests/glprobe.c`](../../tests/glprobe.c) exists
and why it **reads a pixel back**: a shim that exports a name but cannot forward
it returns zero, the frame comes out black, and no amount of grepping for
`GL_RENDERER` tells the two apart.

So the list is generated. [`tools/gen_gl_fwd.py`](../../tools/gen_gl_fwd.py) reads the
export table out of the bundled `libGL.so.1` itself; `make gl-syms-check` fails
the build if the checked-in table and the bundled library disagree, and E60 runs
that check against the real extracted AppDir on every host with python 3.6+.
A newer bundled
libglvnd cannot add an entry point silently.

### 9.4 Trampolines, not wrappers, and the slot that can run code

Each entry point is three instructions:

```asm
glClearColor:
	endbr64
	mov    $0xc1, %r11d            # 193, its own index
	jmp    *glfwd_tab+8*193(%rip)
```

The middle one is the whole of what changed since this section was first
written, and it is worth the paragraph. A table slot is an ADDRESS, so nothing
could happen AT a call: every entry point's fate had to be decided in a
constructor, before the application had asked for anything. That forced two
defects this file used to carry: the host GL stack was loaded in every
process whether or not it would ever be used, and an entry point the host does
not implement was indistinguishable from one that worked and returned zero.

The index is the repair. It is known at ASSEMBLY time, so the trampoline puts
it in `%r11`, the one register the SysV ABI lets a PLT destroy, which is
exactly what makes it free to carry a value across a call boundary, and jumps
through the slot as before. A resolved slot ignores it. An unresolved slot
points at `glfwd_resolve_asm`, and there the index is the whole message.

`glfwd_resolve_asm` is `_dl_runtime_resolve` minus the bookkeeping: save `rax
rdi rsi rdx rcx r8 r9 r10 xmm0-7`, call `glfwd_resolve_one(index)`, restore,
tail-jump to whatever it returned. `and $-16,%rsp` after saving `%rbp` makes
the alignment unconditional rather than argued: a trampoline is reached from
anywhere and the `movaps` faults on a misaligned address. On aarch64 the index
rides in `x17`, because `x16` was already the branch register and both are the
intra-procedure-call scratch registers that exist to be destroyed by veneers.

E69 measures it with the same four shapes E58 uses, and adds the one E58 cannot
ask: **the second call must agree with the first.** Single-sided, a resolver
that got lucky once and a resolver that wrote the right address into the slot
are indistinguishable.

```
E69  OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12]
     second-call-identical=yes absent-returned=0
```

Two tables, not one. `glfwd_tab` is the jump table and stays lazy per name;
`glfwd_addr` is what `dlsym` said, filled in ONE pass when the target loads.
The split is about `dlerror()`: `dlsym` leaves a message behind on every miss,
reading it to clear it is destructive, and doing the whole table in one pass
confines that theft to a single moment, the first GL call in the process,
instead of scattering it through an application's lifetime. The shim says so
under `CROSS_LIBC_DLOPEN_DEBUG=1` when it actually took something.

not a C function with a hand-written prototype. This is not a micro-optimisation.
A tail jump preserves every argument register, the return value and the varargs
count in `%al`, so it forwards **any** signature correctly, including the ones
nobody typed out; a prototype that disagrees with the real one corrupts
arguments silently, and 3470 opportunities to get one wrong is not a risk worth
carrying for a shim whose whole purpose is transparency.

E58 pins the claim rather than asserting it, on the same trampoline shape the
generator emits:

```
E58  OK: ints=204 floats=285.00 varargs=10 struct=[2..12]
```

Eight integer registers, nine float registers, a varargs call whose `%al`
carries the float count, and a struct returned through hidden memory, all
through a jump that knows none of their shapes.

Three details that are load-bearing:

- **Every slot is initialised statically**, to the resolver rather than to
  NULL. A NULL slot is a crash inside a GL call with no explanation; a
  constructor-filled table has an ordering hazard (9.6) that a static
  initialiser does not; and an address decided before the application ran is
  the thing 9.4 above is about. An entry point the target cannot provide ends
  up at `glfwd_absent`, which returns zero in both return registers.
- **`endbr64` is spelled as bytes**, so the floor's assembler cannot be too old
  for it, and the shims are built `-fcf-protection=full`.

  ⚠ **CORRECTION, measured.** This entry previously said the flag makes the
  object carry the matching IBT property note. It does not, on any Debian floor
  tried. Built in `debian:bullseye-slim` and read back with `readelf -n`, the
  shipped `gl-fwd.so` has only `.note.gnu.build-id`; there is no
  `.note.gnu.property` section at all. A trivial one-function shared object
  compiled in the same image behaves identically, with the flag and without
  it. Repeated on `debian:bookworm-slim` (gcc 12.2) and `debian:trixie-slim`
  (gcc 14.2): no note in any of them.

  ```
  gcc -shared -fPIC -O2 -fcf-protection=full t.c -o a.so && readelf -n a.so
  ```

  ⛔ **SECOND CORRECTION, measured, and it reverses part of the first.** The
  paragraph above used to say the note is absent "with `-Wl,-z,ibt,-z,shstk`
  added" as well. **That clause was wrong on all three images.** With that
  linker flag the note IS emitted, every time. The full table, and the reason
  the note would be FALSE if it were forced, is in 9.13 below.

  The `endbr64` instructions ARE emitted; what is missing is the note that
  tells the loader the object is IBT-capable.
  `scripts/verify-artifacts.sh` reports the note's absence on every build, and
  refuses a build whose `endbr64` are missing, which is the part the flag
  actually delivers.
- **The shim refuses to forward to itself.** Its SONAME *is* the name it
  resolves, so anything that hands that name back, such as ld.so matching a request
  against the shim's own libname list, an `CROSS_LIBC_DLOPEN_GL_HOST_DIR` pointing at the
  preload's own directory, or a future loader that dedups by SONAME after
  load, would make every trampoline jump to itself. That is unbounded recursion inside
  the first GL call, with a stack overflow for a diagnostic. One `dladdr` on the
  first resolved pointer turns it into a sentence. E68 fires it deliberately:

```
 [gl-fwd.so] >> target /tmp/glfwd-self/libGL.so.1 -- host library (no vendor
                library for the bundled one)
 [gl-fwd.so] >> libGL.so.1: the target resolves back to this shim
                (/w/AppDir/lib/gl-fwd.so); refusing to forward to ourselves,
                all 3470 entry points return zero
FAILED: no RGB double-buffered visual
```

  The last line is the application's own documented failure, which is the right
  thing for it to see. A guard nobody has fired is a guard nobody knows the
  shape of.

### 9.5 `RTLD_GLOBAL`, asked for by the caller and not by everyone

A plugin does not always declare everything it uses. It can import a symbol with
**no** `DT_NEEDED` edge to whoever defines it and rely on its loader's closure
being in the global scope, which, for `libGL`, is where it sits natively,
because the application has a `DT_NEEDED` on it. A loader that `dlopen`s `libGL`
`RTLD_LOCAL` breaks that without touching either file, and the plugin fails with
`undefined symbol` for a symbol that is present in the process.

The reported instance is classic Mesa's DRI driver importing `_glapi_*` with no
edge on `libglapi.so.0`. **That instance is not reproduced here**, and the last
paragraph of this section says what was found instead. The mechanism is what is
measured.

E54 and E55 reproduce the mechanism in three objects of two lines each rather
than by excavating a 2014 Mesa, because it is a property of `ld.so` and not of
Mesa:

```
E54  FAIL  ./libplug.so: undefined symbol: prov_symbol      middle object RTLD_LOCAL
E55  OK    plug_entry()=8                                   middle object RTLD_GLOBAL
```

Same two files, nothing else changed.

`gl-fwd` therefore passes `RTLD_GLOBAL` when **it** opens the host `libGL`, and
`cld_attempt` is unchanged. Making every cross-libc `dlopen` global would cover the
same case and would additionally put every host ICD's exports in the global
scope ahead of libraries loaded later, a win over bundled definitions that
they do not have natively either, and a direct erosion of T4.2. The narrow
version reproduces the native shape exactly and nothing more.

And the instance, measured on the two Mesas available here:

```
alpine:3.22  Mesa 25.1  no libglapi.so.0 on the system at all; libGL defines no
                        _glapi_* and depends on libgallium-25.1.9.so instead
alpine:3.15  Mesa 21.2  libglapi.so.0 exists, swrast_dri.so imports 9 _glapi_*
                        symbols AND carries libglapi.so.0 in its DT_NEEDED
```

So neither needs the global scope for this. The report that a DRI driver still
relies on it is against Mesa 10.1, comes from outside this repository, and is
plausible, because the `DT_NEEDED` edge is a later addition, but it is not
reproduced here and is not adopted as if it were. What justifies the flag is
E54/E55 plus the fact that `RTLD_GLOBAL` is what a `DT_NEEDED libGL` has
natively: the shim is reproducing a shape, not working around a bug.

### 9.6 Preload constructors run in reverse

⚠ **This section describes a hazard that gl-fwd no longer has, and it is kept
because the mechanism is real and the next shim will have it.** When `gl-fwd`
loaded its target in a CONSTRUCTOR, it needed the bundled libc runtime set that
`cross-libc-dlopen.so`'s constructor puts in the global scope, because a host object
whose musl libc edge was dropped cannot load without it, and so the order of
two constructors mattered. It loads at the first GL call now (9.4), by which
time every preload constructor in the process has long since run, so the race
is gone for this object.

What is not gone is the loader behaviour, and the intuitive answer to it is
still wrong:

```
E56  --preload "A B"   ->  ctor-B first
E57  --preload "B A"   ->  ctor-A first
```

ld.so runs preload constructors in **reverse** of the list. Listing `gl-fwd.so`
after `cross-libc-dlopen.so`, which is what a reader would write and what the
obvious packaging note says, runs it **first**.

E57 is not redundant with E56: without it, "reverse order" cannot be
distinguished from "B always happens to go first".

Rather than depend on an ordering nobody documents, `cross-libc-dlopen.so` exports
an idempotent `cross_libc_dlopen_init_now()` and `gl-fwd` calls it before its first
`dlopen`. That call is now belt-and-braces rather than load-bearing, because the
lazy load made the ordering moot, and it stays for two reasons: it costs one
`dlsym` once, and it keeps the `.preload` order free for the NEXT preload that
does work in a constructor. E56 and E57 are what a packager should read before
writing an ordering note, and they are the reason `.preload` in this repository
has no required order.

### 9.7 End to end, on two host classes, with the third in 9.11

The point of measuring both is that they fail in opposite directions. On a
classic-Mesa host the shim is the only thing that makes GL work; on a glvnd host
GL already worked and the shim's job is to change nothing.

⭐ Two was the whole story when this section was written and it is not now:
9.11 adds the pre-glvnd GLIBC hosts, which are classic like Alpine and glibc
like Debian, and 9.12 adds an AppImage of the other SHAPE. Read those two after
this one; the tables below are still exactly what they say, on the two hosts
they name.

**alpine:3.22, musl, classic Mesa 25.1, no glvnd vendor library:**

| | no shim | with the shim |
|---|---|---|
| `glxgears` | `Error: couldn't get an RGB, Double-buffered visual` (E61) | `GL_RENDERER = llvmpipe (LLVM 20.1.8)` (E62) |
| `glprobe` | `FAILED: no RGB double-buffered visual` (E63) | `OK: GL is complete`, readback `64 128 191 255` (E64) |
| `eglprobe` | `FAILED: eglGetDisplay -> EGL_NO_DISPLAY` (E65) | `OK: EGL is complete` (E66) |
| `vkcube` | n/a | `Selected GPU 0: llvmpipe` (E67) |

**debian:trixie-slim, glibc 2.41, glvnd:**

| | no shim | with the shim |
|---|---|---|
| `glxgears` | `GL_RENDERER = llvmpipe (LLVM 19.1.7)` (E61) | unchanged (E62) |
| `glprobe` | `OK: GL is complete` (E63) | unchanged (E64) |
| `eglprobe` | `OK: EGL is complete` (E65) | unchanged (E66) |
| `vkcube` | n/a | `Selected GPU 0: llvmpipe` (E67) |

E65 is worth reading twice. With **only** the GL shim loaded, EGL still fails on
the classic host: the two dispatchers have independent vendor-discovery
mechanisms (a `libGLX_*.so.0` for GL, a JSON file under
`/usr/share/glvnd/egl_vendor.d` for EGL), so they are genuinely two boundaries
and fixing one does not fix the other. `egl-fwd.so` is the same source file built
with a different table and a different vendor marker.

E67 is the regression case: the shims are preloaded for every binary in the
AppDir, `vkcube` included, and the Vulkan path is unaffected.

Totals with this section in: **40/40 on the musl host** with five named skips,
**45/45 on the glvnd glibc host** with none, **26/26** on each of ubuntu:14.04
and ubuntu:16.04 with nineteen named skips, **7/7** on the gtk4 stage, and
**53/53** in the container suite on x86-64, and **50/50** on aarch64 with the
three skips named in section 8.

### 9.8 What the shim does not do, stated as a number

On Alpine 3.22 the split is:

```
libGL.so.1: 2373 of 3470 entry points resolved from the host library
            (1357 exported, 1016 via glXGetProcAddressARB, 1097 absent)
```

`dlsym` alone finds 1357. Half of what glvnd exports are extension entry points
that classic Mesa implements without putting them in `.dynsym`, and the designed
way to reach those has always been `glXGetProcAddress`; asking it for the misses
adds 1016. The remaining **1097 are extensions this Mesa does not implement at
all**: vendor extensions glvnd knows the names of and Mesa 25.1 has no code
for. They forward to the zero-returning stub.

That is the same answer an application would get natively on that host, where
those names are equally absent. But the number is a property of the host's Mesa,
not of this shim, so the shim reports the split under `CROSS_LIBC_DLOPEN_DEBUG=1`
rather than presenting 2373 as a score. On the glvnd host the same line reads
`3470 of 3470 ... (3470 exported, 0 via glXGetProcAddressARB, 0 absent)`, which
is what transparency looks like when it is measured instead of asserted.

**And calling one is now a line, not a zero.** This was the shim's own worst
failure mode: 1097 silent no-ops by construction, in a repository that spends
more words warning about silent zeros than about anything else. The resolver in
9.4 is what made it reportable: an absent name keeps its slot pointing at the
resolver, so the FIRST call to it arrives somewhere that knows which name it is.

```
 [gl-fwd.so] >> ABSENT entry point called: glFooEXT -- this host's libGL.so.1
                has no implementation; returning zero
```

Not fatal. Returning zero is what the application gets natively on a host where
the name is equally absent, and making it fatal would be a policy decision about
somebody else's Mesa taken inside a shim.

⭐ **The question that could not be asked before: how many of the 1097 does a
real application actually touch?**

```
alpine:3.22, glprobe through the full AppDir
  libGL.so.1: 2373 of 3470 entry points resolved from the host library
  libGL.so.1: 15 of 3470 entry points were CALLED (15 forwarded, 0 absent)
              out of 2373 this host could resolve
  absent entry points this application reached: 0
```

**Zero.** The estimate this replaces was "likely zero, and likely is the
problem". The other number in that line is worth as much: `glprobe` touches
**15 of 3470**, which is 0.4%, and a real GTK4 application (9.11) touches 46
GLES entry points and one GL one, because its renderer is GLES. "It replaces
libGL" has always rested on the export count; these are the first measurements
of use.

### 9.9 What it costs a process that never calls GL

Nothing beyond mapping the shim itself. That is a change: this section used to
record 30 ms and 30 MB of HOST MESA, and the gate that would have avoided them
as deliberately not written.

The shims are preloaded for every binary in an AppDir, so a Vulkan-only run
used to load the whole host GL stack and never touch it. The reason it was not
gated was that the gate under consideration, "does anything in this process
have a `DT_NEEDED` on the soname I am impersonating", means walking every
loaded object's dynamic section, and `d_ptr` in a mapped `PT_DYNAMIC` may be
absolute or link-time depending on the port (7.3). Trading a measured 30 MB for
an unmeasured segfault class was not a trade worth making, and it still is not.

The resolver in 9.4 removes the need for it. Nothing resolves until something
calls, so the question "will this process use GL" never has to be answered in
advance. It answers itself, at the first call, by there being one.

Measured both ways, because each answers half of it. On the clock and the
resident set, which is what the old figure was:

```
vkprobe on alpine:3.22, both shims in the preload, best wall of three
and max RSS of three:

  no shims                          0.28 s   230344 KB
  shims, default (lazy)             0.24 s   230988 KB
  shims, CROSS_LIBC_DLOPEN_GL_EAGER=1    0.36 s   259824 KB
```

The default costs **0.6 MB** over no shims at all, which is the two shim objects being
mapped, and no wall time this measurement can distinguish from noise; the
lazy row coming out 0.04 s FASTER than the no-shims row is what run-to-run
variation looks like at this scale, not an improvement. Eager costs **29 MB and
0.12 s** over lazy, which is the host Mesa closure being mapped and is the
figure this section used to record as the price of the default.

And on the process rather than on a clock, because "it started faster" is not
evidence about WHAT was loaded:

```
E71   OK: shim mapped=1 target mapped=0 (called=-1)      links the soname, no call
E71b  OK: shim mapped=1 target mapped=1 (called=204)     the same binary, one call
E74   Vulkan-only run: 2 shim(s) loaded, 0 resolved, no host GL mapped
E74b  the same shims, after a GL call: 2373 of 3470 entry points resolved
```

E71 alone would also pass if the shim were merely broken, which is why E71b is
the same binary one argument apart.

`CROSS_LIBC_DLOPEN_GL_EAGER=1` restores the old behaviour, resolving everything
before `main()`, so the cost of not doing it stays a measurement rather than a
memory, and so "how much of this dispatcher could this host stand behind" can
still be asked as a question about the host rather than about a particular run.
In that mode the exit summary says the forwarded call count is NOT measured,
rather than printing a smaller number under the same words.

The packaging answer is still better for a bundle with no GL application in it:
do not list the shims in `.preload`. That is a decision the person building the
AppDir can make correctly and the shim cannot.

### 9.10 The generalisation, and the tool that makes it a measurement

The OpenGL gap survived a session because finding it required somebody to
*wonder* whether libglvnd was a loader. That should not depend on wondering: a
bundled object that imports `dlopen` is a loader by construction, and the set of
them is a property of the bundle that can be read off it.

[`tools/plugin_boundaries.py`](../../tools/plugin_boundaries.py) does exactly that, and
E59 runs it against the extracted AppDir with `--check`, which fails on any
loader that is not classified. The demo AppDir has eight:

```
covered     libvulkan.so.1      ICD from /usr/share/vulkan/icd.d      (E30-E37)
covered     libGLX.so.0         glvnd's vendor dlopen                 (E61-E64)
covered     libEGL.so.1         glvnd EGL -> egl_vendor.d             (E65, E66)
unmeasured  libX11.so.6         loadable i18n modules, on a build with them
n/a         libGLdispatch.so.0  glvnd internal dispatch, no host plugin
n/a         libdecor-0.so.0     libdecor-rs: decorations linked in
n/a         vkcube, vkmark      dlopen the BUNDLED libvulkan/libX11/libxcb
```

Two of those rows are the argument for the tool.

**`libGL.so.1` is not on the list, and that is the correct answer.** The object
that actually `dlopen`s the vendor library is `libGLX.so.0`; glvnd's
`libGL.so.1` is a re-export layer over it and imports no `dlopen` at all. A
human enumerating "which bundled libraries load host plugins" writes down
`libGL.so.1`, because that is the name in the failure. The tool writes down the
object that does the loading.

**`libdecor-0.so.0` is on the list because the tool found it**, not because
anyone thought of it. It turned out to be benign, being `libdecor-rs` with the
decoration plugins linked in, so its only `dlopen` is a lazy one for the bundled
`libwayland-client.so.0`. But "benign, checked" and "never looked at" are
different states and only one of them was true before.

⭐ **And the argument for the tool got its strongest instance after this
section was written.** The gtk4 AppDir from 9.12 is 272 libraries rather than
91, and thirty seconds of the same command says:

```
covered 2   n/a 1   unmeasured 3   UNCLASSIFIED 9
```

Two of the three `unmeasured` are `libgbm.so.1` and `libva.so.2`. The AppImage
exists now, and section 9.19 measures `libva.so.2` with mpv and a real Intel
media driver. `libgbm.so.1` remains unmeasured. One of the nine UNCLASSIFIED is
**`libepoxy.so.0`**, which is
itself a GL entry-point loader: it `dlopen`s `libGL`, `libEGL` and `libGLESv2`
by soname and resolves through them. That is the same DISPATCHER shape as
libglvnd, in the path of the application section 9.12 uses, and it is very
likely why gtk4-demo's counts come out 1 GL and 46 GLES. Nobody has looked at
it. It is recorded in CONTINUE 4.2 rather than investigated here, and it is
recorded because the tool found it rather than because anyone wondered.

The third verdict, **`unmeasured`**, exists for the same reason and is
deliberately not folded into either of the others. `libX11.so.6` can load i18n
modules from `/usr/lib/X11/locale` when it is built with them; nothing here has
run that. Calling it `covered` because it is "just another host object" is the
exact move that produced the OpenGL gap, and a state with no word for it becomes
invisible again.

The table also carries the boundaries this AppDir does **not** have, so that an
AppImage which bundles them is classified on sight rather than investigated from
scratch: `libva.so.2` (`<name>_drv_video.so` from `/usr/lib/dri`),
`libvdpau.so.1`, `libasound.so.2` (ALSA plugins), `libOpenCL.so.1`
(`/etc/OpenCL/vendors`), `libgbm.so.1`. Each is the same shape as the OpenGL one
and none of them is a libc problem. The `libva.so.2` boundary is fixed and
measured in section 9.19. The others are named, not fixed.

### 9.11 The third host class: pre-glvnd GLIBC

Sections 9.1 to 9.10 measure two host classes, and the sentence they support,
"every musl distro, and every pre-glvnd glibc distro", had evidence for one
of them. Ubuntu 14.04 and 16.04 are the other: glibc, classic Mesa, no
`libGLX_<vendor>.so.0` anywhere.

| host | libc | Mesa | `glxgears` | `glprobe` | `eglprobe` |
|---|---|---|---|---|---|
| alpine:3.22 | musl | 25.1.9 | llvmpipe (LLVM 20.1.8) | OK | OK |
| ubuntu:14.04 | glibc 2.19 | 10.1.3 | Gallium 0.4 on llvmpipe (LLVM 3.4) | OK | OK |
| ubuntu:16.04 | glibc 2.23 | 18.0.5 | llvmpipe (LLVM 6.0) | OK | fails, and see below |
| debian:trixie | glibc 2.41 | 25.0.7 (glvnd) | unchanged | unchanged | unchanged |

Mesa versions read off the package or `libgallium-<version>.so`, not off the
renderer string: `llvmpipe (LLVM 20.1.8)` names LLVM, and 25.1.8 is not a Mesa
version that exists. This table said it for one revision.

**The resolution counts match an independent run on hardware nobody here has.**
@Samueru-sama reported
Ubuntu 14.04 from a seven-distro matrix on an RX 580:

```
reported : 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
measured : 1889 of 3470 resolved (1405 exported, 484 via glXGetProcAddressARB, 1581 absent)
```

Different hardware, different display path, different Mesa point release, same
numbers. A generated table that reproduces to the entry point across eight Mesa
versions is the strongest thing said about it anywhere in this report.

**Two findings came out of 16.04 and neither is about the shim.**

The first is the `/etc/ld.so.cache` blindness for the fourth time. The host
`libGL.so.1` loads and 2354 of 3470 entry points resolve from it; then Mesa
`dlopen`s its own `swrast_dri.so`, which needs `libLLVM-6.0.so.1`, which is
reachable on that host only through the cache the bundled `ld.so` is patched to
ignore (E13b). `libGL error: unable to load driver` and then an X error from
`glXCreateContext`, a display fault, apparently. Same bug as
`CUDA_ERROR_NO_DEVICE` (E44) and `glXCreateContext failed` (E53a). **E77**
measures it on every host and scores the DIAGNOSTIC rather than the outcome:
the outcome depends on how a host packages its driver, but "when this bites,
the process names the library it could not find" holds everywhere.

The second changed how this suite predicts. `eglprobe` fails on 16.04 with the
shims, and natively:

```
native eglprobe on ubuntu:16.04, no AppImage, no preload, no shim
  EGL_VERSION : 1.4   EGL_VENDOR : Mesa Project
  readback rgba : 0 0 0 255 (want ~64 128 191 255)
  FAILED: the pixel does not carry the colour that was set
```

Mesa 18.0.5 does not produce that pixel on that host at all, so a shim that did
would be inventing one. **E78 and E79 build and run the probes natively, and
E64 and E66 are predicted against that** rather than against a constant. The
shim's claim is transparency; the yardstick for transparency is the host. This
also corrects a hypothesis offered in the issue, that the readback fails
because the GL and EGL shims do not share dispatch state. There are no shims in
the native run.

### 9.12 A real application, a third dispatcher, and the bug they found

Everything above runs against the host-drivers demo AppImage: `glxgears`,
`vkcube`, and two probes written for this repository. That AppDir bundles a
dispatcher and no Mesa, which is one of the two shapes an AppImage comes in and
not the common one.

The other shape is self-contained: `gtk4-demo`, 272 bundled libraries, its own
Mesa, its own `libEGL_mesa.so.0`, a real GTK4 application. On musl Alpine, with
the shims in `.preload`, it died with `SIGFPE`. Without them it ran.

**The shim was wrong, and had been wrong since it was written.**
`glfwd_host_has_vendor()` asked only whether the HOST had a vendor library.
That is the right question for an AppImage built to use host drivers, which
bundles a dispatcher and no vendor, so if the host has none either there is
nothing to dispatch to. It is the wrong question for an AppImage that bundles
its whole Mesa: Alpine has no vendor library, the shim concluded "no vendor
anywhere", and forwarded a bundled GTK4 onto Alpine's Mesa. Two Mesas, one
process.

`glfwd_bundle_has_vendor()` asks the other half. If the BUNDLE carries a vendor
library, the bundled dispatcher is what the application was built and tested
against and the shim leaves it alone. That is also what makes this shim safe to
put in every AppImage's `.preload` rather than only in host-drivers ones.

```
E80a  as shipped, no shims          rc=143  (still running when the timeout ended)
E80   gl + egl + gles shims         rc=143  (was 136 = SIGFPE)
E81   target: the bundled dispatcher, because the BUNDLE has its own vendor library
E82gl/egl/gles   3470 of 3470, 44 of 44, 358 of 358 entry points resolved
E83   gtk4-demo called 1 GL, 13 EGL and 46 GLES entry points
```

**E83 is why the GLES shim exists.** GTK4 renders through GLES, not desktop GL.
`libGLESv2.so.2` is a glvnd dispatcher with the same shape as the other two and
it finds its implementation the way EGL does, through a JSON file under
`/usr/share/glvnd/egl_vendor.d`; on a classic host there is none, and without
`gles-fwd.so` those 358 entry points are 358 silent zeros. The table is 358
entries read out of the `libGLESv2.so.2` this AppDir bundles, which is why
the shim could not exist before this AppDir did, since the generator's one rule
is that the list comes out of the object being replaced.

`libGLESv1_CM.so.1` is not covered. No AppImage available here bundles one, and
that is the whole reason; one `make gles-syms` against an AppDir that has one is
the entire job.

⚠ **Note what found this.** Four synthetic cases, two host classes and 3470
generated trampolines did not. One real application did, on the first run.

---

### 9.13 The IBT property note: emitted after all, and it would be a lie

T-17 recorded that no Debian gcc emits the note, tried three ways. ⛔ **One of
those three ways was recorded wrong.** Re-measured on the same three images,
with a control that must report nothing so that "found none" and "cannot see
one" are distinguishable:

| build | bullseye 10.2 | bookworm 12.2 | trixie 14.2 |
|---|---|---|---|
| `-fcf-protection=full` | none | none | none |
| `-fcf-protection=full -Wl,-z,ibt,-z,shstk` | **IBT, SHSTK** | **IBT, SHSTK** | **IBT, SHSTK** |
| a `.note.gnu.property` block in the source | none | none | none |
| nothing asked for (control) | none | none | none |

Two things follow, and the second is the one that matters.

**The source-emitted note does not survive the link.** `GNU_PROPERTY_X86_FEATURE_1_AND`
is ANDed across every input, and glibc's `crti.o` carries no property on any of
the three images, so a note written by hand in `gl-fwd.c` is dropped. That is
the approach T-17 proposed, and it does not work.

**The linker flag does emit a note, and the note would be false.** Measured on
the object it produces:

| symbol | first instruction | reached by |
|---|---|---|
| `probe_answer` | `endbr64` | a normal call |
| `_init` | `sub $0x8,%rsp` | `DT_INIT`, which `ld.so` calls through a pointer |
| `_fini` | `sub $0x8,%rsp` | `DT_FINI`, the same |

`_init` and `_fini` come from `crti.o` and `crtn.o`. An indirect call landing
on an instruction that is not `endbr64` is exactly what IBT exists to fault on,
so an object marked IBT-capable whose `DT_INIT` target is not `endbr64` is
asserting a property it does not have.

⭐ **So the absence of the note is the linker being right**, not a toolchain
gap to work around. Forcing it with `-z ibt` would trade a real absence for a
false claim, which is the forbidden pattern
[`../conventions/forbidden-patterns.md`](../conventions/forbidden-patterns.md) calls
"asserting a build property the toolchain does not deliver".

⚠ **What is UNVERIFIED:** whether a CET-enforcing host actually faults on such
an object. No host here enforces IBT, so the fault is reasoned from how IBT
activation works and has not been observed. What IS measured is every row of
both tables above.

The measured consequence for this project: on x86-64 `gl-fwd.so` carries 3478
`endbr64` and no note; on aarch64 it carries none of either, and CET is an x86
feature so that is correct rather than a gap.

⭐ **And the flag accounts for six of those 3478.** Built with
`-fcf-protection=full` removed, the same object has **3472**. The other 3472
are the trampolines' own, spelled as literal bytes in `gl-fwd.c` so the floor's
assembler cannot be too old for them (9.4), and no compiler flag removes those.

| x86-64 `gl-fwd.so` | `endbr64` |
|---|---|
| default build | 3478 |
| built without `-fcf-protection=full` | 3472 |
| aarch64, either way | 0 |

Two things follow.

⛔ **A check that refused a build with no `endbr64` could never have fired**, and
`scripts/verify-artifacts.sh` briefly had one. The trampolines supply 3472
whatever the flag does, so the count says nothing about whether the flag
arrived. It reports the number now and asserts nothing about it.

⚠ **Removing the flag does not remove `endbr64` from the shims**, which matters
to anyone removing it in order to avoid the instruction. It removes six of
them. The instruction is a four-byte NOP on any CPU without CET, so what it
costs on a host that does not implement CET is the four bytes.

---

### 9.14 A guard that could not refuse, and a guard that could not see itself

Deep review pass 1 asked whether every guard added on this branch can actually
refuse. Two could not, and neither was broken in the way it looked.

⭐ **Corrected after the fact: the ratchet described below no longer exists.**
Everything measured in this section stands and is why it was replaced. Section
4 now refuses any occurrence and carries no pin, no budget and no tolerance,
so the drift recorded here has nothing left to accumulate in. Its scope also
widened from Markdown to C, shell, Python, YAML and Makefile comments, and it
counts a dash that wraps at the end of a line, which the counting version never
saw. The measurements below are the reason for that change and are left in the
present tense they were written in.

**The dash ratchet.** `scripts/check-drift.sh` section 4 counts ` -- ` across
every tracked `.md` outside `docs/history/` and compares it to a number written in
the script. A previous session appended `A sentence -- with a dash.` to
`docs/building.md`, ran the check, read "at the budget", and recorded the
ratchet as broken.

The counter was never wrong. Measured, per commit on this branch, counting
every occurrence the way the check did at the time:

| commit | ` -- ` in tracked `.md` outside `docs/history/` | pin in the script |
|---|---|---|
| `b162b39` initial | 270 | none yet |
| `bc29fce` front-door rewrite | 236 | set to 236 |
| `e09e128` portable variant | 235 | still 236 |
| `f6d126e` PROGRESS rewrite | 228 | still 236 |

The refusal condition was `count > pin`. At `e09e128` the tree carried 235, so
the planted dash took it to exactly 236, and 236 is not greater than 236. The
check printed the truth. The expectation that it would print 237 assumed the
tree was at the pin, and it was one under.

⛔ **The defect is the slack, and the slack is structural.** Nothing lowered
the pin when the count fell. The script printed a line asking the next reader
to lower it, and three commits running the next reader did not, so a guard
that refuses one dash too many silently became a guard that would accept eight
more before saying anything.

⚠ **A second defect surfaced while writing this section: the counter counted
what the rule exempts.** `docs/conventions/prose.md` says a flag, a literal
inside a code block and a shell comment are all `--` doing their own job. The
counter read the file raw and counted those too. Measured on the tree with
this section in it:

| | count |
|---|---|
| every ` -- ` in tracked `.md` outside `docs/history/` | 233 |
| inside a fenced code block | 10 |
| inside a code span | 5 |
| actual prose, which is what the rule is about | 218 |

Two consequences, and the second is the one that forced the change. A document
that added a correct shell snippet was refused for being correct. And a
rewrite that traded a prose dash for a code one netted to zero and passed
unseen. ⛔ Together with an exact pin it also made this section unwritable:
recording the planted sentence means putting the planted sentence in a
document. The counter now skips fences and spans, and the pin is the prose
number.

Three runs against the script as it stands, on a tree that is otherwise clean:

```
$ printf 'A sentence -- with a dash.\n' >> docs/building.md
$ sh scripts/check-drift.sh
  FAIL 219 dashes used as punctuation, and the pin is 218.
$ echo $?
1

$ perl -0pi -e 's/ -- / instead /' docs/building.md
$ sh scripts/check-drift.sh
  FAIL 217 dashes used as punctuation, and the pin is still 218.
$ echo $?
1

$ printf '\n~~~\nrun this -- and that\n~~~\n' >> docs/building.md
$ sh scripts/check-drift.sh
  218, at the pin. It may fall, and a fall lowers the pin with it.
$ echo $?
0
```

The first is the rule. The second is what carries the pin down with the count,
and it is the half that was missing. ⭐ **It caught its own author within the
hour.** A rewrite of `docs/integrating.md` dropped one prose dash, the count
fell to 217, and the check refused the commit until the pin came down with it.
That is the whole mechanism working: under the old one-sided version the slack
would simply have widened by one and nobody would have been told. The third is the exemption the rule
always claimed and the check never honoured. `scripts/verify-gates.sh` plants
the first of the three on every run, so the arming is checked rather than
remembered.

**The cited-path check, on the citation shape this repository actually uses.**
Section 2 of the same script reads every repository path a document cites and
opens it. It anchored the path on an opening backtick and required a closing
backtick straight after, which matches `` `scripts/build.sh` `` and nothing
else. The common form here is a command:

```
⚠ The ratchet is `sh scripts/check-prose-dashes.sh`, and it is a ratchet rather
        docs/conventions/prose.md, line 39, before this change
```

No script of that name has ever existed in this repository. The ratchet is
section 4 of `check-drift.sh`. The citation survived the entire branch because
the check that exists to catch a stale citation could not see one written in
front of a command, and the citation it could not see was a citation of
itself.

Widened to allow backtick-free, space-terminated words before the path, and to
drop the closing-backtick requirement so a path followed by its arguments
counts:

| | paths checked |
|---|---|
| before | 80 |
| after | 87 |

Both measured on the tree as it stands with this section in it. Three of the
seven newly visible paths did not exist. One is the real defect
above, the check-prose-dashes name, fixed in `docs/conventions/prose.md`. One
belongs to `Azathothas/TEMPLATE` and is cited at a URL as not being in this
tree. One is `tests/bindprobe`, which is ours, is built from
`tests/bindprobe.c`, and is cited as a command rather than as a file. The last
two are exempt by name.

⚠ **`*` had to enter the path character class in the same change.** Without it
the class stops at the hyphen in `` `src/gl-fwd-*.h` ``, so the wildcard skip
never sees a wildcard and the check reports the truncated stem, everything up
to and including the hyphen, as a file that does not exist. The widened
pattern did exactly that on its first run.

⚠ **And this paragraph is why the check skips a fenced block.** Recording a
broken-path finding means writing the broken path down. The quotation above
sits in a fence and is read as the transcript it is; the two sentences here
name the defect without putting it in citation shape, the way
`scripts/verify-gates.sh` assembles its plants at runtime rather than letting
them sit in the file as literals. Both dodges are the same dodge: a checker
that reads the tree cannot tell a claim from a quotation of a broken one.

**And two refusals that had never been planted at all.**
`scripts/package-release.sh` carries the last two guards before anything is
published: every artefact against its manifest entry, and both archives being
flat. Neither had been made to fire. Both were, against a synthetic build
directory of two files and a hand-written manifest, so no real build was
needed:

| | result |
|---|---|
| a manifest that matches its files | exit 0, `both archives are flat: LICENSE build-manifest.json cross-libc-dlopen.so gl-fwd.so` |
| one artefact edited after the manifest was written | exit 1, `gl-fwd.so does not match its manifest entry`, with both hashes printed |
| the `tar` invocation changed to archive the staging directory instead of its contents | exit 1, `the tar has a path separator in it, so it would extract into a directory`, with the offending listing printed |

⚠ The third is planted in the SCRIPT rather than in the data, and that is the
right place for it: the assertion's own comment says a nested directory "is
exactly the kind of thing that reappears when somebody changes a tar
invocation", so changing the tar invocation is the defect it names.

⛔ **One guard in this family is still unproven:** `release.yml` refuses to
publish a tag whose commit is not an ancestor of the default branch. Firing it
needs a tag, and pushing one publishes a release.


---

### 9.15 The demo AppImage: which repository, and how its integrity is checked

The AppImage suite downloads two binaries from a third party and runs them. A
sha256 digest is what makes the suite's results about a known artefact. Run
[32948154287](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32948154287)
refused with

```
suite: demo.AppImage (x86_64) sha256 is 8f6e390aa36c34f59363b916c29eec3fe95ce931be0c8a89f1e80a43d0981dbe,
expected 712766f8a4dc6b5ea3193ed7bb0282b64c7b781f7334056416edd3d00e8960bd
```

⭐ **The check did its job.** What follows is about what to do next, which is a
policy question and not a bug.

**Correcting the account of when.** It was recorded here that the assets were
re-uploaded during that run. Measured from the API, they were not:

| event | time |
|---|---|
| run created | `2026-08-26T08:31:03Z` |
| run ended, refusing | `2026-08-26T08:31:41Z` |
| every asset on that release re-created | `2026-08-26T08:32:37Z` |

The re-upload post-dates the run's end by 56 seconds. So the mismatch the run
hit was caused by an EARLIER replacement, and the assets were then replaced
again a minute later. The object the run downloaded no longer exists, so
whether `8f6e390a` was a complete asset or a torn read cannot be established
now. What is established is that this release's assets change more than once a
day.

**Which repository.** `pkgforge-dev/Anylinux-AppImages` is the upstream:
`fork: false`, 234 stars.

⚠ **Correcting the dependency.** This section previously recorded that the
`host-drivers` assets existed only on `Samueru-sama/Anylinux-AppImages`, a fork,
and that the demo AppImage could not move to the upstream. That premise no
longer holds. The upstream now publishes the same three assets the suite uses:
`gtk4-demo`, `gtk4-demo-host-drivers` and `vkcube+glxgears-host-drivers-demo`,
for both architectures. Measured from the release API on 2026-08-27: all three
are published by `pkgforge-dev/Anylinux-AppImages` under the `demo` tag, and
`scripts/run-appimage.sh` and `experiments/appimage.ps1` take every asset from
it. Nothing in the suite depends on a fork.

| asset | upstream |
|---|---|
| `gtk4-demo-<arch>.AppImage` | published |
| `gtk4-demo-host-drivers-<arch>.AppImage` | published |
| `vkcube+glxgears-host-drivers-demo-<arch>.AppImage` | published |

**The policy, and why it is the one that was available.**

| option | verdict |
|---|---|
| pin to an immutable release | ⛔ not available. Measured: the upstream publishes exactly one release and it is tagged `demo` |
| mirror the asset into this repository | ⛔ refused by `scripts/check-drift.sh` section 2c, which rejects any tracked `*.AppImage` by shape |
| mirror to a release of our own | needs a published release, and nothing has been published yet |
| ⭐ verify against the release API's live digest at download time | adopted. The `demo` tag is rolling, so no checked-in digest can be current; the only ground truth is what the release publishes when the suite runs |

⛔ **A checked-in pin is gone, and that is the policy.** The earlier record here
described re-pinning as a maintained act. That premise no longer holds: the
`demo` tag is rolling, so any pinned digest is stale before it lands and every
run would need a re-pin to survive. `scripts/suite-lib.sh` now reads the digest
the release API publishes at download time, verifies the bytes against it, and
refuses on a mismatch, with a re-read once so a re-upload in progress is not
blamed on the network. The checked-in pins were removed from
`scripts/run-appimage.sh` and `experiments/appimage.ps1` in the same change.

The verification is exercised on every run of the AppImage suite: the digest is
read before a cached copy is trusted, so a cache hit from an earlier run is
re-verified and re-downloaded when the tag has moved.

⚠ **The `docs/ground-truth.md` inventory was taken against a specific binary**
and stays bound to that binary's digest, which is named in that document. The
suite now runs whatever the release publishes today, so a changed answer is a
finding rather than a regression, exactly as before.

---

### 9.16 What this branch stopped measuring

Deep review pass 2 asked one question: what did this branch stop measuring?
Two answers, and neither showed up as a failing case, because both of them
went green.

**1. The ARM runner arrived and section P did not notice.**

`.github/workflows/gates.yml` added `ubuntu-24.04-arm` with a reason written
into the matrix: it is "the row where CI is STRONGER than the machine this
project was built on", because "the aarch64 trampolines have only ever run
under qemu-user, which emulates the instructions and not a memory model".

Section P of `experiments/30-run-tests.sh` is the case that runs those
trampolines. It opens by saying "This machine is x86_64 and there is no
aarch64 silicon to borrow", which was true when it was written, and it
cross-compiles with `aarch64-linux-gnu-gcc` and runs the result under
`qemu-aarch64-static`. It does that unconditionally.

⛔ **So on the aarch64 runner, E76 and E76b ran an aarch64 binary under an
aarch64 emulator on an aarch64 CPU**, and passed. Measured, from the aarch64
evidence job of run
[32950783301](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32950783301):

```
-- P. the aarch64 trampolines, RUN -----------------------------
  E76    MATCH predicted=OK    OK: first-call ints=204 floats=285.00 varargs=10 struct=[2..12] second-call-identical=yes absent-returned=0
  E76b   MATCH predicted=OK     [tgt-fwd.so] >> libtgt.so: 5 entry points, none resolved yet
```

Two green cases, on the one host where the emulator is the thing standing
between the measurement and the point of it. The branch bought real silicon
and then declined to stand on it.

Section P now picks its vehicle from the host and PRINTS which one it used,
because a reader holding one log has no other way to tell:

| host | compiler | vehicle |
|---|---|---|
| aarch64 | `gcc` | native. No emulator in the path |
| x86_64, cross toolchain and qemu present | `aarch64-linux-gnu-gcc` | `qemu-user`. Userspace emulation, not a memory model |
| x86_64, neither present | none | E76 and E76b SKIP, naming what is missing |

⚠ The predictions did not change. Same case ids, same expected exit, same
needles. Only the vehicle did, and the stage no longer installs an emulator
for the architecture it is standing on.

**2. A marker that stopped being read, and four documents that did not.**

The markers were removed on this branch and the feature is on by default. Two
of the places that explained behaviour by the marker were comments on a case:

```
# already carries .foreign-dlopen-enabled -- quick-sharun's spelling of the
# marker, still accepted -- so the feature turns itself on
        experiments/40-appimage.sh, E40, before this change
```

Nothing in `src/` reads that file. Measured: `git grep` for the name across
`src/` and `tests/` returns one hit, and it is a comment in `src/cld-env.h`
saying the marker is gone.

⭐ **E40 kept passing, for a reason its own comment did not give.** Its claim,
that this is the case which forces nothing, did not weaken. It got stronger:
the feature turning itself on with no marker present is a larger statement
than it turning itself on because a marker is present. That is why nobody
noticed, and it is the shape worth naming. A case whose stated mechanism has
been replaced by a better one reads exactly like a case that is fine.

Four places carried the stale claim, and `docs/AGENTS.md` carried it in a
table of names that must not be renamed on pain of turning E30, E37a and E43a
into silent passes. That protection is real and it belongs to two other
things, measured on the tree as it stands:

| name | still load-bearing? |
|---|---|
| the AppDir's dispatcher slot | yes. `.preload` names it and our build is copied into it. ⚠ Its NAME is not load-bearing and must not be spelled by us: 9.17 has upstream changing it |
| the `ANYLINUX_*` env spelling in `experiments/40-appimage.sh` | yes. 13 call sites, none touched by this branch, and upstream's binary understands no other spelling |
| `.foreign-dlopen-enabled` | ⛔ no. Nothing in `src/` reads it |

⚠ Whether upstream's own binary still reads the marker is NOT measured here.
No case depends on the answer, because every arm sets the variable explicitly.

---

### 9.17 Upstream shipped this project, and the AppDir changed shape

Verifying against the current asset, the suite got further and then refused on
both architectures, in run
[32951892766](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32951892766):

```
demo.AppImage (x86_64) sha256 ok
==> debian:trixie-slim  (41-extract.sh)
cp: cannot stat 'AppDir/lib/foreign-dlopen.so': No such file or directory
suite: extraction failed
```

⭐ **A sha256 check says the bytes are what the release publishes. It says
nothing about the layout inside them.** The layout moved.

**What the verified AppImage now contains.** Extracted and measured here:

| `AppDir/lib` | |
|---|---|
| `cross-libc-dlopen.so` | 51 608 bytes. Debug tag `[cross-libc-dlopen]`, and it reads both the `CROSS_LIBC_DLOPEN_*` names and the `ANYLINUX_*` aliases. It is a build of THIS project |
| `gl-fwd.so` | 566 608 bytes, SONAME `libGL.so.1`. This project's forwarding shim |
| `egl-fwd.so` | 27 200 bytes |
| `gles-fwd.so` | 78 864 bytes |
| `foreign-dlopen.so` | ⛔ gone |

⛔ **Upstream adopted this project and renamed the slot to it.** The one file
the whole A/B replaces used to be `lib/foreign-dlopen.so` and is now
`lib/cross-libc-dlopen.so`. `experiments/41-extract.sh` reads the name out of
the AppDir and writes it to `.cld-slot`; `40-appimage.sh` takes it from there
rather than either file spelling it. Both spellings are accepted by name, the
one that was found is printed, and an AppDir with neither is a refusal that
lists what is actually in `lib/`. A guess would be worse than a refusal: the
A/B is one `cp` into one path, and a wrong path makes both arms identical and
reports them agreeing.

⚠ **The rename is the loud half. The quiet half is `.preload`.**

| | |
|---|---|
| recorded in `../ground-truth.md` | `path-mapping.so`, `anylinux.so`, `cross-libc-dlopen.so` |
| shipped by the verified build | the same three, then `gl-fwd.so`, `egl-fwd.so`, `gles-fwd.so` |

`41-extract.sh` saved the shipped `.preload` as the baseline that every later
case restores from before appending the one shim under test. With this project's
shims already in that list, every case whose whole point is a shim's ABSENCE
would have run with upstream's copy of it present, appended a duplicate line,
and passed. ⛔ Nothing would have reported anything: no MISMATCH, no skip, no
warning. The suite would have gone green measuring the opposite of its claim.

Two files now, and the difference between them is the point:

| file | what it is |
|---|---|
| `.preload.shipped` | what the AppImage ships, byte for byte. A record. Never restored from |
| `.preload.baseline` | the same list with this project's own forwarding shims removed. What the cases restore from |

⭐ **The derived baseline is exactly the old shipped list**, which is the
check that it reconstructs the contrast the cases were written against rather
than inventing one:

```
dispatcher slot: lib/cross-libc-dlopen.so
shipped .preload:
    path-mapping.so
    anylinux.so
    cross-libc-dlopen.so
    gl-fwd.so
    egl-fwd.so
    gles-fwd.so
  ⚠ removed from the restore baseline: gl-fwd.so egl-fwd.so gles-fwd.so
AppDir: 94 libraries, bundled glibc 2.44
```

That runs on every extraction. A suite that edits the artefact under test and
does not say so is worse than one that refuses.

**The inventory, re-measured against the verified build.**

| row | verdict |
|---|---|
| bundled glibc 2.44 | unchanged, confirmed |
| legacy split libs present, `libanl.so.1` absent | unchanged, confirmed |
| `.foreign-dlopen-enabled` present, 0 bytes | unchanged, confirmed |
| `gconv/` bundled, beside `locale/` and `vkmark/` | unchanged, confirmed |
| `.preload` contents | ⛔ CHANGED, above |
| the dispatcher's filename | ⛔ CHANGED, above |
| bundled `cross-libc-dlopen.c`, 24 785 bytes | ⛔ GONE. The only `.c` in the AppDir is `.anylinux.c`, 20 731 bytes, a `linuxdeploy-plugin-checkrt` derivative belonging to `anylinux.so`. It names this project 0 times |
| stub export counts 13, 4, 6, 2 | ⚠ NOT RE-ESTABLISHED |
| 51 sonames | ⚠ NOT RE-ESTABLISHED |

⚠ **Why two rows are UNVERIFIED rather than corrected.** Four counting methods
were tried against the new binary and none reproduces 13, 4, 6, 2:

| method | libpthread | libdl | librt | libutil |
|---|---|---|---|---|
| `objdump -T`, `DF .text` | 12 | 3 | 5 | 1 |
| the same, versioned only | 12 | 3 | 5 | 1 |
| `objdump -T`, every global or weak | 28 | 10 | 14 | 6 |
| `nm -D --defined-only` | 24 | 6 | 10 | 2 |

Every one of the first method's four numbers is exactly one below the recorded
value, which is the signature of a counting difference rather than four
independent changes. The old binary no longer exists, so the method cannot be
tested against it, and artefact and method cannot be separated. ⭐ The claim
those numbers exist to support does hold: all four are single digits, so they
are stubs. The soname total is the same shape of question, measured at 49
distinct sonames over 55 regular files and 35 symlinks.

⛔ **The A/B's control arm no longer contrasts, and that IS the finding.**

The "as shipped" arm used to be upstream's own shim, which could not load a
host driver. It is now a build of this project, older than the working tree,
still carrying the `ANYLINUX_*` aliases this branch removed. E30 and E37a are
the controls for that arm, and they are what make the patched arm a
measurement rather than a coincidence.

⚠ **Read their predictions carefully, because the log line is misleading on
its own.** Both are `predicted=OK`, which is about the exit status: the
program is expected to run cleanly. What they assert is the NEEDLE, and the
needle is the complaint being reproduced:

| case | asserts the output contains |
|---|---|
| `run E30 OK "NO-DEVICES" probe_verdict 1` | `NO-DEVICES` |
| `run E37a OK "zero accessible devices" render_verdict vkcube --c 20` | `zero accessible devices` |

So a MISMATCH here means the as-shipped arm found a device. Run
[32953461170](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32953461170),
x86-64, the suite's first completed run:

```
E30    MISMATCH predicted=OK    DEVICES  (  device[0] : llvmpipe (LLVM 20.1.8, 256 bits))
E37a   MISMATCH predicted=OK    Selected GPU 0: llvmpipe (LLVM 20.1.8, 256 bits), type: Cpu
```

Both arms now work, so neither case can distinguish them. ⭐ **The right
response is not to flip the predictions.** A control that has stopped
contrasting has stopped measuring, and rewriting it to expect success would
convert two controls into two cases that pass whatever the shim does, which is
the exact shape this repository calls a silent pass.

⚠ The honest control for "the feature is absent" is an AppDir with NO
dispatcher in `.preload`, not an AppDir carrying somebody else's. Choosing
that, or something else, changes what the suite claims about upstream and is a
decision rather than a repair. It is left open deliberately.

**Two further MISMATCHes, and one of them could not say why.** E33 and E34
reported `feature off: 3 / 0 load` and `feature on : 0 / 0 load` on the musl
host and the same zero total on the glibc one. A total of 0 means the
feature-ON corpus run produced no verdict line at all, so both cases were
scored against nothing. ⛔ **Its stderr went to `/dev/null`**, which is T-13's
shape for the third time in this tree, and the reason was in the stream that
had been discarded. It is captured now and printed when, and only when, the
run produces no verdict line.

E49 went MISMATCH on aarch64 with one truncated line of preamble, for the same
family of reason: `experiments/40-appimage.sh`'s `run` printed a 96-column
summary of a failure where `30-run-tests.sh`'s has printed the whole captured
output since T-13 closed. Both harnesses do now. ⛔ **E50's assertion is left
alone until E49 can be read.** It requires exactly two live musl-against-glibc
ABI hazards and aarch64 measured zero, which would be a genuine architectural
difference worth recording, except that E49 failed in the same stage and a
hazard count taken from a crossing that did not happen measures nothing.

---

### 9.18 aarch64 has a live ABI hazard x86-64 does not, and the probe aborted on it

E49 was unreadable until `experiments/40-appimage.sh` gained the full MISMATCH
dump. With it, the cause is the last four lines of the case's own output, run
[32954726201](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32954726201),
aarch64:

```
  T1.6 -- mutex and condition variable across the boundary
    ok   guest locked+unlocked a host mutex   returned 0
    ok   and left it unlocked
    ok   guest allocated a mutex with its own sizeof
    ok   host locked the guest's mutex        returned 0
malloc(): invalid size (unsorted)
Aborted (core dumped)
(exit 134, wanted OK, needle: ABI CROSSING PASSED)
```

⭐ **The cause is in the same dump, eleven lines earlier**, in the size table
that T1.7a prints before any crossing is attempted:

| | musl guest | glibc host | |
|---|---|---|---|
| `pthread_mutex_t` | 40 | 48 | ⛔ diverges on aarch64 |
| `pthread_mutex_t` | 40 | 40 | agrees on x86-64 |

⛔ **The overflow is inside the GUEST, and it needs no crossing at all.**
That is worth stating precisely, because the first reading of this was wrong
and the fix built on it did not work. `abi_new_mutex()` in
`tests/abi-guest.c` is four lines:

```
pthread_mutex_t *m = malloc(sizeof *m);        /* the GUEST's 40 */
if (!m) return NULL;
if (pthread_mutex_init(m, NULL) != 0) ...      /* resolves to OURS, writes 48 */
return m;
```

The guest allocates its own size. Its `pthread_mutex_init` is glibc's, because
making every reference in the guest resolve to this process's libc is the
entire point of the thing under test. So glibc writes 48 bytes into a 40-byte
allocation before anything is handed back, and the host's `free()` further down
is merely where glibc notices.

⚠ **Whether it is noticed depends on allocator rounding, and the write is
real either way.** Measured on x86-64 with a guest planted to report and
allocate eight bytes short: glibc rounds a 32-byte request up to a 40-byte
usable chunk, the overflow lands in that padding, and nothing aborts. Planted
32 bytes short instead, it escapes the padding and aborts. ⛔ A silent one is
the worse outcome of the two, and it is the one a size pair closer together
produces.

⛔ **This is a real hazard, not a harness artefact:** no loader can make a
40-byte allocation hold a 48-byte mutex, and the same shape reaches any
musl-built object that allocates a `pthread_mutex_t` with its own `sizeof` in
a glibc process on aarch64.

**The measured contrast, one run, both architectures:**

| | x86-64 | aarch64 |
|---|---|---|
| E49 | MATCH, `ABI CROSSING PASSED: 26 checks, 0 failed` | ⛔ MISMATCH, `exit 134` |
| E50 | MATCH, 2 live hazards: `regexec`, `nftw` | MISMATCH, 0 |

⚠ **E50's zero was not a finding.** The abort came before the hazard scan, so
the count was taken from a process that had already died. That is why E50's
assertion was left alone: a hazard count from a crossing that did not happen
measures nothing, and pinning aarch64 to zero would have recorded the crash as
an architectural virtue.

**The probe declines the CALL now, and reports it.** `tests/abi-host.c`'s own
header already says T1.7 writes divergent structs behind a guard band "because
an overrun that only happens on success is the most misleading result
available". T1.6 had the same overrun and no band, and only x86-64 had ever run
it, where the sizes happen to agree. It is reported the way every other size
divergence in that file is reported, through a `DIFF` line and a `LIVE HAZARD`
explanation rather than through `ok()`, because a hazard is not a failed check:
it is a thing no loader can fix.

⚠ **The first version of that guard wrapped the wrong thing**, and this is
recorded rather than quietly corrected because the failure it produced looked
exactly like success. It guarded the host's `pthread_mutex_lock`, which is the
crossing the case is about, and left `g_newmtx()` being called. Run
[32955888055](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32955888055)
printed the hazard, in full, and then died at the same `free()` with the same
`exit 134`. ⭐ It did move E50 from 0 live hazards to 1, because the hazard
line was printed before the abort, which is precisely the kind of partial
improvement that reads as a fix.

⛔ **Proven by reproducing the abort on x86-64, not by reasoning about it.**
A guest was rebuilt to report AND allocate a short mutex, which is what a real
musl guest does on aarch64. Both hosts were built from the same tree and run
against the same planted guest:

| guard | exit |
|---|---|
| wrapping the host's lock, the first attempt | ⛔ **134**, SIGABRT. `g_newmtx()` is still called and the overflow is inside it |
| wrapping the call, as it stands | **0**, `ABI CROSSING PASSED: 25 checks, 0 failed` |

⚠ The delta has to be large enough to escape glibc's chunk rounding for the
abort to appear at all, which is the same caveat as above. At eight bytes short
both hosts exit 0 and the difference is visible only in the output: the old one
still prints `ok guest allocated a mutex with its own sizeof`, because it
called the function that does the overflowing write.

The reported form, from the same runs:

```
    ok   and left it unlocked
    DIFF a mutex the guest allocates and inits host=40 guest=8
         LIVE HAZARD: pthread_mutex_t is 40 bytes here and 8
         there. The guest allocates its own size and calls
         pthread_mutex_init, which resolves to OURS and writes this
         size into it. NOT PERFORMED: on this pair it is an
         out-of-bounds write inside the guest, and the allocator
         aborts the process on the next free.
    ok   guest signalled a host condvar       guest signal returned 0, host wait returned 0

ABI CROSSING PASSED: 25 checks, 0 failed
```

and the same binary against an unplanted same-libc guest still reports
`ABI CROSSING PASSED: 27 checks, 0 failed` with the crossing performed, so the
guard is not simply always firing. ⭐ The run reaches the end now, which matters beyond E49: T1.7b and
E50's hazard scan are downstream of the abort and had never executed on aarch64
at all.

**Both numbers now measured, one run,
[32957101324](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32957101324):**

| | E49 | E50, live hazards |
|---|---|---|
| x86-64 | MATCH, 26 checks | **2**: `regexec` stride, `nftw` FTW_D |
| aarch64 | MATCH, 24 checks, on all four host stages | **3**: those two, plus `a mutex the guest allocates and inits` |

⭐ **The difference is exactly the mutex, so E50 probes for it rather than
carrying a table of architectures.** Two is the count where the two
`pthread_mutex_t` sizes agree; where they diverge there is a third, and the
divergence is printed by `abi-host`'s own size table in the same output that
carries the count. That is E22's shape: read the condition, then assert
against it. A per-architecture number would have been a second thing to
maintain and the first to go stale.

⚠ Two aarch64 checks fewer than x86-64, 24 against 26, and that is the guard:
the two `ok()` calls it skips are the allocation and the lock it declines to
perform.

### 9.19 A real VA-API application crosses the musl driver boundary

E95 through E100 measure the driver search contract with a stand-in driver.
The external Alpine host in section 2 measured the same path with mpv
using the `mpv-v0.41.0-anylinux-x86_64.AppImage` artifact and the host's real
`iHD_drv_video.so`. The AppImage carried glibc and the host driver was built
for musl.

The VA-API-only run used a null video output, so neither Vulkan nor OpenGL
could make a software decode look successful:

```bash
APPIMAGE=mpv-v0.41.0-anylinux-x86_64.AppImage
SAMPLE=sample.mp4
LIBVA_DRIVER_NAME=iHD CROSS_LIBC_DLOPEN_DEBUG=1 "$APPIMAGE" --no-config --hwdec=vaapi-copy --vo=null --ao=null --frames=300 --msg-level=vd=debug "$SAMPLE"
```

The H.264 sample ended before the 300-frame limit. mpv decoded the complete
six-second file and exited zero. The relevant output was:

```
[cross-libc-dlopen.so] >> LIBVA_DRIVERS_PATH=/usr/lib/dri:/lib/dri
[cross-libc-dlopen.so] >> cross-libc-dlopen: rewriting /usr/lib/dri/iHD_drv_video.so
[cross-libc-dlopen.so] >> cross-libc dlopen success: /usr/lib/dri/iHD_drv_video.so
[vd] Trying hardware decoding via h264-vaapi-copy.
Using hardware decoding (vaapi-copy).
[vd] Decoder format: 478x850 [0:1] nv12 bt.709/bt.709/bt.1886/limited/auto CL=mpeg2/4/h264 crop=478x850+0+0 A=none
VO: [null] 478x850 nv12
Exiting... (End of file)
```

Two rendering runs kept the same VA-API decoder and changed only the video
output. `--vo=gpu-next --gpu-api=vulkan` loaded both Intel Vulkan host drivers
and rendered NV12 frames. `--vo=gpu --gpu-api=opengl` rendered 60 frames over
EGL. The EGL forwarder resolved all 44 entry points, received 15 calls, and
reported no absent call.

⚠ The dependency walk printed this line before the successful driver load:

```
cross-libc-dlopen: dependency libigdgmm.so.12 could not be opened at all
```

The host had `/usr/lib/libigdgmm.so.12`, which resolved to
`libigdgmm.so.12.10.0`. The complete hardware decode shows that this diagnostic
did not describe the final load result in this run. Why the dependency walk
missed it remains UNVERIFIED.

---

---

[REPORT index](README.md) | [previous](08-test-results.md) | [next](10-measured-versus-assumed.md)
