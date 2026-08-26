## 6. Goal 2: what works, and how the last blocker fell

### 6.1 What works

```
###### T2.2 cross-libc load the real host ICD ######
-- OFF --
FAILED: dlopen: libc.musl-x86_64.so.1: cannot open shared object file
-- ON --
  handle          : 0x55557a900a70
  vk_icdGetInstanceProcAddr: 0x7f8ded0d5d80
  vkCreateInstance          : 0x7f8ded0d44f0
OK: host ICD loaded and callable

###### T2.4 corpus, zero-regression gate ######
  before: TOTAL=247 OK=2
  after : TOTAL=247 OK=247
  regressions: 0

###### T2.3 debug trace ######
  times libvulkan_lvp.so rewritten: 1     (rewritten once, then cached)
  attempts to load a musl libc: 0
```

T2.4 is the result that separates a fix from a demo. Every one of the 247 musl
libraries in Alpine's `/usr/lib` loads into the glibc process, up from 2, with
zero regressions. Through the bundled Vulkan loader, `vkCreateInstance` against
the host ICD returns `VK_SUCCESS`.

### 6.2 T3.2, solved: an unversioned reference does not get the default definition

This was the open failure:

```
[Vulkan Loader] ERROR: setup_loader_term_phys_devs: Call to
  'vkEnumeratePhysicalDevices' in ICD /tmp/xdg/.cross-libc-dlopen-dbdb70ee.so
  failed with error code VK_ERROR_OUT_OF_HOST_MEMORY
vkEnumeratePhysicalDevices reported zero accessible devices.
```

It was attributed to glibc-vs-musl ABI differences. **It is not that**, and the
first measurement that mattered was reproducing it with no musl in sight.

#### The reproduction that broke it open

`debian:trixie-slim`, one libc, glibc 2.41 throughout. Debian's own
`libvulkan_lvp.so` is a glibc object. The only change from the working case is
that cross-libc-dlopen intercepts the load, and the only reason it intercepts is
that the ICD manifest was given an absolute `library_path` (Debian ships a bare
soname, which cross-libc-dlopen deliberately never touches, which is why nobody had
seen this on Debian):

```
=== feature OFF ===  deviceName = llvmpipe (LLVM 19.1.7, 256 bits)
=== feature ON  ===  WARNING: [lvp_device.c:1315] Code 0 : VK_ERROR_OUT_OF_HOST_MEMORY
                     ERROR: setup_loader_term_phys_devs ... VK_ERROR_OUT_OF_HOST_MEMORY
```

Same libc on both sides. So the ABI hypothesis is dead, and the mechanism is
the rewriting itself.

#### The chain, one measurement per link

Debian ships Mesa's `__FILE__` strings, so the failure names its own line.

| Link | How | Result |
|---|---|---|
| which Mesa call fails | the message itself | `lvp_device.c:1315` = `lvp_init_wsi()` |
| which WSI backend | gdb `FinishBreakpoint` on each `wsi_*_init_wsi` | `wsi_display_init_wsi` -> `VK_ERROR_OUT_OF_HOST_MEMORY`; x11 and wayland both `VK_SUCCESS` |
| which line inside it | gdb, stepping by line, both runs side by side | diverges at `wsi_common_display.c:2323`, `u_cnd_monotonic_init()` returns `thrd_error` where the working run returns 0 |
| which libc call | breakpoints on the three calls that inlines to | `pthread_condattr_init` 0, `pthread_condattr_setclock` 0, **`pthread_cond_init` 22 = `EINVAL`** |
| *which* `pthread_cond_init` | `info symbol $pc` at the breakpoint | failing run enters libc+`0x909f0`, working run libc+`0x91b00` |

```
$ nm -D /lib/x86_64-linux-gnu/libc.so.6 | grep -w pthread_cond_init
00000000000909f0 T pthread_cond_init@GLIBC_2.2.5     <- the failing run lands here
0000000000091b00 T pthread_cond_init@@GLIBC_2.3.2    <- the working run lands here
```

`pthread_cond_init@GLIBC_2.2.5` is `__pthread_cond_init_2_0`, kept for binaries
from before the 2003 condition-variable ABI change. Its entire body is
`if (cond_attr != NULL) return EINVAL;`. Mesa always passes an attribute,
because a monotonic clock is the only reason to build one.

#### Stated as a property of libc alone

E22 and E22b, no Vulkan, no musl, no AppImage: one small object, built once,
then version-stripped exactly the way a host driver is:

```
  E22    versions stripped   probe_cond_init() = 22
  E22b   versions intact     probe_cond_init() = 0
```

**An unversioned reference does not get the default definition of a symbol.**
A stripped object has only unversioned references. So does every musl-built
object, which never had version information to begin with. That is why the
same failure appeared on Alpine and on Gentoo with a glibc driver, and why it
looked like an ABI problem for as long as it did.

#### The fix

[`src/version-compat.c`](../../src/version-compat.c) defines the trapped names itself.
The preload is ahead of libc in the global lookup scope, so every unversioned
reference in the process lands there, and each definition forwards to the
default one.

Finding "the default one" is the part that needed care. `dlsym` is not an
answer: measured in **E27**, `dlsym(RTLD_NEXT, "pthread_cond_init")` returns the
**obsolete** definition on glibc 2.31 and the default one on 2.41. So the
version name is read out of the defining object's own `.gnu.version_d`, the
entry whose versym lacks the hidden bit, and handed to `dlvsym`, which is
correct on both. No version string is hardcoded anywhere.

Which names to cover is not a judgement call either.
[`tools/version_traps.py`](../../tools/version_traps.py) computes the set from a libc:
a name defined at two or more versions whose `st_value` **differs**. Same
address at several versions is re-versioning, not an ABI change. The glibc 2.34
libpthread merge does that to 191 symbols and none of them can matter.

```
glibc 2.42  multi-version, same address (harmless): 191    different address (traps): 38
glibc 2.41  multi-version, same address (harmless): 191    different address (traps): 33
glibc 2.31  multi-version, same address (harmless):  10    different address (traps): 21
```

`make traps` fails the build if a libc has a trap `version-compat.c` neither
forwards nor explicitly declines, so a future glibc cannot introduce one
silently (**E26**).

That is not a hypothetical. Run against glibc **2.42** (Arch, Fedora 44) rather
than the 2.31 and 2.41 this was developed on, the audit failed with five
uncovered names:

```
cfgetispeed  cfgetospeed  cfsetispeed  cfsetospeed  cfsetspeed
                                       default=GLIBC_2.42  others=GLIBC_2.2.5
```

glibc 2.42 added arbitrary terminal baud rates, so the `GLIBC_2.2.5`
definitions speak the old `Bnnn`-encoded `speed_t` and the new ones take a real
number of bits per second. Nothing in a graphics driver closure calls them,
which is the point: the set grew under a glibc newer than any this was tested
on, and an audit that enumerates rather than reasons is what noticed. Now
covered; audited clean on glibc 2.31, 2.41, 2.42 (Arch) and 2.42 (Fedora 44). Three are declined on purpose, with reasons: `memcpy`
(both definitions satisfy the memcpy contract, checked byte-for-byte over 4096
size and alignment combinations in **E25**; interposing every memcpy in a
rendering process to fix nothing is not a trade worth making) and
`sys_nerr`/`_sys_nerr` (data objects, which a forwarder cannot alias, and from
glibc 2.32 neither has a default version at all, so an unversioned reference
fails loudly instead of quietly).

#### End to end

`alpine:3.22`, musl host, the demo AppImage bundling glibc 2.44, forced onto
Alpine's own musl-built lavapipe:

| | as shipped | feature off | **this repo, feature on** |
|---|---|---|---|
| `vkprobe` | segfault | `VK_ERROR_INCOMPATIBLE_DRIVER` | **1 device, llvmpipe** |
| host `/usr/lib` loadable | n/a | 2 / 177 | **177 / 177** |
| libc families mapped | n/a | n/a | **one** |
| `vkcube` | `reported zero accessible devices` | n/a | **`Selected GPU 0: llvmpipe (LLVM 20.1.8)`** |
| 100 load/unload cycles | n/a | n/a | **rss +68 kB, fds +0, copies +0** |
| 60 s continuous render | n/a | n/a | **rss/fds/threads flat at 6 s, 33 s, 60 s** |

The `feature off` column is why the rest of the table means anything: the same
command with the same binaries cannot use the host driver at all.

And the same thing with nothing forced at all. **E40** replaces one file
inside the AppDir, no `CROSS_LIBC_DLOPEN_*`, no `VK_DRIVER_FILES`, the marker the AppDir
already carries turning the feature on by itself:

```
as shipped   Do you have a compatible Vulkan installable client driver (ICD) installed?
with this    Selected GPU 0: llvmpipe (LLVM 20.1.8, 256 bits)
```

#### What this also fixed

The same defect ran the other way on a **glibc** host. Reported independently by
@QaidVoid on Gentoo
with a real `radv`, and reproduced here on `debian:trixie-slim`, whose glibc
2.41 is **older** than the bundled 2.44, so by construction nothing can be
missing and nothing needs rewriting:

| | vkcube |
|---|---|
| as shipped, feature on | `vkEnumeratePhysicalDevices reported zero accessible devices` |
| feature off | renders |
| this repo, feature on | renders |

Turning the feature on used to destroy a working configuration. See 3.4 for the
second half of that, which is that it should not have been rewriting anything
there in the first place.

#### One claim retracted

While reviewing this I asserted, in the issue thread, that lavapipe "has no
libdrm on the path at all". That is false and is corrected there. Alpine's
`libvulkan_lvp.so` links `libdrm.so.2` directly and references 35 drm symbols.
What is true, and measured:

```
$ readelf -d /usr/lib/libvulkan_lvp.so | grep -c libdrm_amdgpu
0
LD_DEBUG=libs, filtered to `calling init:`   ->   /w/AppDir/lib/libdrm.so.2
```

`libdrm` is on the path and the **bundled** copy is the one loaded, which is 3.2
working rather than libdrm being absent. `libdrm_amdgpu`, the one that reads
`amdgpu.ids` through `AMDGPU_ASIC_ID_TABLE_PATHS`, genuinely is not involved,
because lavapipe never references it. The conclusion held; the reason given for
it did not.

#### `glxgears`, the OpenGL path

**This paragraph used to end "no loader shim can supply a file the distribution
does not ship", and that sentence was wrong.** It is kept here, corrected, rather
than quietly rewritten, because the way it was wrong is the most transferable
thing in this report.

What was measured, and is still true: Alpine's `mesa-gl` is classic Mesa, not
libglvnd, so there is no `libGLX_<vendor>.so.0` for the AppImage's bundled
libglvnd to `dlopen`. That is host packaging, not libc.

What was asserted and never tested: that this made it unfixable. A shim cannot
supply the missing *file*, but it can replace the object that was looking for
it. `glxgears` now renders on Alpine's classic Mesa, and so does everything else
`glprobe` exercises. Section 9 is the whole chain.

---

---

[REPORT index](README.md) | [previous](05-design-b-generated-shim.md) | [next](07-closed-source-driver-and-abi.md)
