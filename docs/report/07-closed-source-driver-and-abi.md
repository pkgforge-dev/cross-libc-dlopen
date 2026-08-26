## 7. The closed-source driver, the ABI, and real silicon

Three things this report carried as UNVERIFIED for its whole life are measured
here: a **proprietary** host driver, the **cross-libc ABI** microtests T1.3-T1.7,
and rendering on an actual **GPU**. Cases E41-E53 in
[`experiments/40-appimage.sh`](../../experiments/40-appimage.sh); the suite reports
them on both hosts and SKIPS them by name where the capability is absent.

The headline is not the one the task predicted, so it goes first.

### 7.1 A proprietary driver is the least likely library to need this fix

The target is NVIDIA's WSL CUDA userspace, reachable through `/dev/dxg`. It is
the one class of host library nothing else here covers: a vendor binary that
cannot be inspected, cannot be rebuilt, and was linked against a libc nobody in
this project chose.

It loads, and it works:

```
E41   handle          : 0x55557363f2d0
      provenance      : /usr/lib/wsl/lib/libcuda.so.1
      cuInit          : ok
      driver version  : 13.0
      devices         : 1
      device[0]       : NVIDIA GeForce RTX 3050 Ti Laptop GPU
      device memory   : 4095 MiB
      OK: 1 CUDA device(s), 4096 bytes round-tripped through the GPU and verified
```

The round trip is deliberate. A handle proves only that `ld.so` was satisfied;
`cuMemcpyHtoD` and `cuMemcpyDtoH` with a byte-for-byte compare exercise ioctls
on the device node, the vendor's own threading and its allocator, under a libc
runtime the vendor never saw, and none of them fails.

**And every control passes too.** E41b runs the identical command with
`CROSS_LIBC_DLOPEN=0`; E41c runs it with **no preload in the process
at all**, so neither this repository's shim nor upstream's nor the version-trap
forwarders are present; E43a runs the shipped one. All four get the same result.
That is not a defect in the test, it is the answer:

```
$ objdump -T /usr/lib/wsl/lib/libcuda.so.1 | grep -o 'GLIBC_[0-9.]*' | sort -uV
GLIBC_2.2.5
```

A vendor ships against the oldest floor it can, precisely so its blob runs on
everything. Nothing in it can be missing from a bundled glibc 2.44, so the shim
has nothing to do, and E42 measures that directly: **0 objects rewritten, 3
examined and left unchanged**, the E39 rule arriving from a real vendor binary
instead of a synthetic probe. The claim E41/E41b support is therefore the
*regression* claim: turning the feature on does not break a driver that already
worked.

E46 puts the vendor's own binary on the end of it. `nvidia-smi` is NVIDIA's, not
ours; it `dlopen`s `libnvidia-ml.so.1` itself, and under the AppImage's bundled
glibc on **Alpine** it reports the GPU. E46a is its control, and on a musl host
it is unambiguous: the same binary run without the AppImage's runtime does not
execute at all. The precise reason is worth stating, because the obvious phrasing
is wrong, because musl's `ld.so` is never asked. The binary's `PT_INTERP` names
`/lib64/ld-linux-x86-64.so.2`, Alpine has no such file, and the kernel fails the
`execve` with ENOENT before any loader runs. E46a requires that message NOT to be
a shared-library one, so the case cannot pass on E44's failure by mistake.

```
E46    GPU 0: NVIDIA GeForce RTX 3050 Ti Laptop GPU (UUID: GPU-df849629-...)
E46a   env: can't execute '/usr/lib/wsl/lib/nvidia-smi': No such file or directory
```

### 7.2 What the vendor stack did need: two condvar ABIs in one process

Section 6.2 established the version-binding trap from libc alone. The CUDA stack
is the first place it has been caught in **shipping third-party software**, and
it is caught by reading the answer out of the running process rather than
inferring it. [`tests/bindprobe.c`](../../tests/bindprobe.c) walks each loaded object's
relocations, reads the address the loader put in the slot, and names the file and
symbol version behind it. `LD_DEBUG=bindings` cannot do this: it prints the
version a reference *asked for*, and for this trap the whole point is that the
reference asks for nothing.

Microsoft's `libdxcore.so`, which `libcuda.so.1` loads to reach `/dev/dxg`,
carries no symbol versioning at all:

```
$ readelf -V /usr/lib/wsl/lib/libdxcore.so | grep -c 'Version needs'
0
$ readelf -V /usr/lib/wsl/lib/libd3d12.so  | grep -c 'Version needs'
0
$ readelf -V /usr/lib/wsl/lib/libcuda.so.1 | grep -c 'Version needs'
1
```

So it imports every libc symbol unversioned, structurally identical to a
musl-built object, and to an object this project's own rewriter has stripped.
`libd3d12.so` is the same shape and is in the *graphics* stack rather than this
one (section 7.5); it is shown here only because two independent vendor blobs
being built this way is the point.

[`tools/manual/trap_users.py`](../../tools/manual/trap_users.py) intersects an object's imports with
the traps of the libc it will resolve against:

```
$ python3 tools/manual/trap_users.py $APPDIR/lib/libc.so.6 /usr/lib/wsl/lib/libdxcore.so
libc .../libc.so.6: 38 trap(s), 191 benign re-versioning(s)

== libdxcore.so
   imports              : 140
   trapped names among them: 6
   symbol versioning    : ABSENT, so every one of those references is unversioned
                          and binds the OBSOLETE definition
     memcpy                     default=GLIBC_2.14   obsolete=GLIBC_2.2.5
     pthread_cond_broadcast     default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_destroy       default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_signal        default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_timedwait     default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
     pthread_cond_wait          default=GLIBC_2.3.2  obsolete=GLIBC_2.2.5
```

NVIDIA's own `libnvidia-ml.so.1` names ten trapped symbols and is versioned, so
every one of them binds correctly. Which object is at risk is decided by how it
was linked, not by who wrote it.

The consequence, measured with the AppImage exactly as it ships (E43a):

```
  pthread_cond_wait
      libdxcore.so                 -> libc.so.6 @GLIBC_2.2.5
      libcuda.so.1.1               -> libc.so.6 @GLIBC_2.3.2
      VERDICT: MIXED (2 implementations)

  BINDINGS MIXED: 6 symbol(s) measured, 5 MIXED
```

One process, one driver stack, two different implementations of five condition
variable entry points, and the two differ in how they read the first eight
bytes of a `pthread_cond_t`, which is the 2003 ABI change section 6.2 is about.
With this repository's preload the same measurement is (E43):

```
      libdxcore.so                 -> cross-libc-dlopen.so+0x6c80
      libcuda.so.1.1               -> cross-libc-dlopen.so+0x6c80
      VERDICT: uniform

  BINDINGS UNIFORM: 6 symbol(s) measured, 0 MIXED
```

**What this does not claim.** The mixed binding is latent, not currently fatal:
`cuInit` returns 0 and the GPU round trip succeeds in both states. Whether a
`pthread_cond_t` ever crosses the `libdxcore`/`libcuda` boundary is not visible
from outside two closed-source blobs. If one ever does, the two sides read it
two different ways. The fix removes the question rather than answering it.

### 7.3 One blind spot, three sightings

The `/etc/ld.so.cache` item has been an open design question since the first
pass. It now has a symptom, from a real driver, three times over.

WSL makes its GPU userspace reachable by writing a file:

```
$ cat //wsl$/podman-machine-default/etc/ld.so.conf.d/ld.wsl.conf   # a real WSL distro
# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [automount]
# ldconfig = false
/usr/lib/wsl/lib
```

Nothing else names that directory. Anylinux patches `ld-linux.so` to skip the
cache (E13b), so `--library-path` is the only discovery mechanism left, and
whatever assembles it decides what exists.

**Sighting one, compute (E44).** `libcuda.so.1` opens by absolute path and loads
fine. Inside `cuInit` it `dlopen`s `libdxcore.so` by **bare soname**, which
`cross-libc-dlopen` deliberately never intercepts, so it reaches `ld.so` and is not
found. The error the user sees is not "cannot open shared object file":

```
FAILED: cuInit -> 100          # CUDA_ERROR_NO_DEVICE
```

E45 appends the directories `/etc/ld.so.conf` names and the same command
completes the GPU round trip. The conf file is plain text, so reading it gets the
benefit of the cache without touching the binary cache whose parsing is why the
cache was inhibited.

**Sighting two, Design R.** `runtime-select` assembles its own
`--library-path` from a hardcoded `rs_host_libdirs[]`, which has the same blind
spot. This one was found by reading the list rather than by a failure, so it was
measured afterwards, building the file from the commit before the change and
after it against the same driver:

```
=== runtime-select, before the conf-dirs change ===
   directories on the path: 8
   /usr/lib/wsl/lib present: NO
   FAILED: cuInit -> 304 CUDA_ERROR_OPERATING_SYSTEM
=== runtime-select, after the conf-dirs change ===
   directories on the path: 10
   /usr/lib/wsl/lib present: yes
   OK: 1 CUDA device(s), 4096 bytes round-tripped through the GPU and verified
```

A **third** distinct symptom for one cause, and again not a missing library: 304
rather than E44's 100, because the process is running the host's glibc 2.41
rather than the bundled 2.44 and `libcuda` gives up at a different point. The fix
is `rs_conf_dirs()`, which reads `/etc/ld.so.conf`, follows its `include` globs
with recursion bounded by both depth and a total file budget, sorts each
directory's entries so the path is reproducible, and appends what it finds
**after** the hardcoded list, so bundled and host-runtime directories keep their
existing precedence. E52 is the after-state as a standing case; the before-state
above is a one-off, because keeping it would mean shipping a switch that exists
only to turn a bug back on.

**Sighting three, graphics (E53a).** The strongest one, because the symptom
implicates the wrong subsystem entirely. Mesa's `d3d12_dri.so` `dlopen`s
`libd3d12.so` by bare soname; sharun assembles the path; sharun's host-GPU
directory list is hardcoded and contains `/run/opengl-driver/lib` and
`/run/current-system/sw/lib` but not `/usr/lib/wsl/lib`. What the user sees:

```
Error: glXCreateContext failed
```

That reads as a display or driver fault. It is a missing directory. `LD_DEBUG=libs`
is what settles it:

```
897:  find library=libd3d12.so [0]; searching
897:    trying file=/w/AppDir/lib/libd3d12.so
897:    trying file=/usr/lib/x86_64-linux-gnu/libd3d12.so
897:    trying file=/run/opengl-driver/lib/libd3d12.so
897:    trying file=/run/current-system/sw/lib/libd3d12.so
                                               ... and never /usr/lib/wsl/lib
```

E53 hands sharun the conf-derived directories through its own
`SHARUN_FALLBACK_LIBRARY_PATH`, with no file edited and nothing patched, and the
AppImage renders on the GPU. All three sightings are one computation, and that
computation now lives **upstream**:
[pkgforge-dev/Anylinux-sharun@`54208d2`](https://github.com/pkgforge-dev/Anylinux-sharun/commit/54208d2bc7d4c919ba46a6c234f6af7f8426b537) adds the `/usr/local/*`
directories and appends the ones it scrapes out of `/etc/ld.so.cache`. The
patch this repository carried is deleted rather than kept in parallel. What that
change does not reach, namely musl's `/etc/ld-musl-<arch>.path`, the multiarch
triplets past three, and the non-FHS prefixes, is recorded in
[`../ground-truth.md`](../ground-truth.md) with the measurement
behind it, because a cache scrape can only name a directory that held a library
when `ldconfig` last ran.

### 7.4 The cross-libc ABI, measured

T1.3 through T1.7 were SKIPPED and UNVERIFIED for the whole project. They are
written now: [`tests/abi-guest.c`](../../tests/abi-guest.c) is one source file built
twice, by glibc on the floor and by musl on Alpine, and
[`tests/abi-host.c`](../../tests/abi-host.c) drives the crossings. The size table both
sides fill comes from one inline function in
[`tests/abi-abi.h`](../../tests/abi-abi.h) compiled into both, so the two columns can
differ only because the headers do.

The musl build is loaded **through `cross-libc-dlopen` itself**, which is what drops
its libc edge, with no `patchelf` and no stand-in. E48 is the control that fails:

```
E48   FAILED: dlopen: libc.musl-x86_64.so.1: cannot open shared object file
E49   ABI CROSSING PASSED: 26 checks, 0 failed
E47   ABI CROSSING PASSED: 27 checks, 0 failed        (same-libc control)
```

Every crossing holds. Memory allocated in the musl object is freed by the
process and the reverse; an `errno` set inside it is read outside it in the same
thread; a `FILE*` opened by the process is written from inside it and read back;
a mutex made on either side is locked from the other; and a condition variable
the process waits on is signalled from inside it. Both sides reach one `malloc`,
one `free`, one `__errno_location`, one `pthread_mutex_lock` and one `stdout`
FILE object.

**The size divergences are real and mostly harmless, and the report can finally
say which.** A size table alone cannot tell those apart, so the probe measures
offsets too:

```
    regmatch_t             guest=16       host=8        <-- DIVERGES
    struct rusage          guest=272      host=144      <-- DIVERGES
    struct sched_param     guest=48       host=4        <-- DIVERGES
    ucontext_t             guest=936      host=968      <-- DIVERGES
    FTW_D                  guest=2        host=1        <-- DIVERGES   (all seven)
    O_LARGEFILE            guest=32768    host=0        <-- DIVERGES
    sizeof regoff_t        guest=8        host=4        <-- DIVERGES
    off rusage.ru_maxrss   guest=32       host=32
    off rusage.ru_nivcsw   guest=136      host=136
    off stat.st_mode       guest=24       host=24
    off stat.st_size       guest=48       host=48
    off dirent.d_name      guest=19       host=19
    off sched.priority     guest=0        host=0
```

Every field the probe measures is at the same offset in both. `struct rusage`
differs by 128 bytes of trailing reserved space and `struct sched_param` by 44;
neither moves a field anybody reads.

Which leaves the direction that does break, and it is not the one the hazard list
implied. Handing the guest storage the host allocated is safe, because the guest
calls **glibc's** implementation, which writes glibc's layout into glibc-sized
memory: all four guard bands survive (T1.7b). The hazard is one step further on,
where the guest reads a glibc-filled struct back at its **own** offsets:

```
  T1.7c -- the guest reading back a struct glibc filled
    DIFF regexec, read back at own stride     host=7 guest=12884901888
         LIVE HAZARD: regoff_t is 4 bytes here and 8 there
    same getrusage, read back at own offset   host=6084 guest=6084
    DIFF nftw, dirs counted with own FTW_D    host=2 guest=0
         LIVE HAZARD: FTW_D is 1 here and 2 there
```

Nothing crashes. `regexec` reports a match ending at byte 7 and the musl-built
caller reads 12884901888 out of the same array; `nftw` walks a tree with two
directories in it and the musl-built caller counts none.

Six hazards were listed. They do not all end in the same place, and the
difference between measured and argued is worth keeping:

| Hazard | Verdict | On what basis |
|---|---|---|
| `regmatch_t` / `regoff_t` stride | **LIVE** | measured: host reads 7, guest reads 12884901888 from the same array |
| the seven `FTW_*` values | **LIVE** | measured: host counts 2 directories, guest counts 0 |
| `struct rusage` | benign | measured: sizes differ by 128 bytes of trailing reserve, `ru_maxrss` and `ru_nivcsw` are at the same offsets, and the guest reads the same value the host does |
| `struct sched_param` | benign | measured: `sched_priority` is at offset 0 in both, and the guard band around a host-allocated one survives the guest filling it |
| `ucontext_t` | **argued, not measured** | 936 vs 968 bytes, and nothing here calls `getcontext`/`swapcontext` across the boundary, so no crossing exists to measure. It would matter to a guest that made or swapped a context the process also touched |
| `O_LARGEFILE` | **argued, not measured** | 0 on glibc x86-64, `0100000` on musl. A guest passing musl's value to glibc's `open` sets the kernel flag glibc considers implied on 64-bit, which is a no-op there; that is a reading of the two headers, not a test |

E50 asserts the count of LIVE rows, so it fails if a future libc moves one.

No loader shim can fix the live two: an offset compiled into an object is not
something a preload can reach. They are a property of loading musl-built code
into a glibc process, and the honest statement is now four measured verdicts and
two arguments rather than a worry about six.

### 7.5 Hardware, at last, and the caveat that was wrong twice

"No GPU" was the standing caveat of this whole project. It was wrong the first
time (there are two GPUs, and the NVIDIA one is live from Linux) and wrong again
in its correction (`/dev/dri` is absent, so radv/anv/radeonsi are out, but they
are not the only way to reach a GPU).

Mesa's **d3d12 Gallium driver** does not need a DRM render node. It talks to
`/dev/dxg` through Microsoft's `libdxcore`, and Debian packages it:
`/usr/lib/x86_64-linux-gnu/dri/d3d12_dri.so`. That makes the host's own OpenGL
driver a hardware driver, and the AppImage's bundled libglvnd finally has a real
vendor library to drive.

Rung 1 of the diagnostic ladder first, natively, with no AppImage involved:

```
$ GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA \
  xvfb-run -a -s '-screen 0 1024x768x24 +extension GLX +render' glxgears -info
GL_RENDERER   = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)
GL_VERSION    = 4.6 (Compatibility Profile) Mesa 25.0.7-2+deb13u1
GL_VENDOR     = Microsoft Corporation
579 frames in 5.0 seconds = 115.707 FPS
```

Then through the AppImage, which is 7.3's third sighting and its resolution:

```
E53a  Error: glXCreateContext failed                                (as it stands)
E53   GL_RENDERER   = D3D12 (NVIDIA GeForce RTX 3050 Ti Laptop GPU)  (+ conf dirs)
      606 frames in 5.0 seconds = 120.965 FPS
      507 frames in 5.0 seconds = 101.138 FPS      (the next interval)
```

**No file is modified and nothing is patched, but four environment variables
are set**: `SHARUN_FALLBACK_LIBRARY_PATH` with the directories `/etc/ld.so.conf`
names, and `GALLIUM_DRIVER`, `MESA_D3D12_DEFAULT_ADAPTER_NAME` and
`LIBGL_ALWAYS_SOFTWARE=0` to choose the hardware driver and which of the two
GPUs it drives. E40 remains the case that forces nothing; this one is not that
case and does not claim to be. The first of those four is the only one this
project is responsible for, and it is the one the sharun patch removes the need
for.

**E53b does not flip.** With the feature off the same command still renders, and
saying otherwise would be claiming a control that did not happen. The host GL
stack here is glibc-built against glibc 2.41, older than the bundled 2.44, so
there is nothing for the shim to do, the same reason as E41b and E42. What E53
measures is that the path works on hardware, not that the shim made it work.

Vulkan stays on lavapipe. Mesa's Vulkan-on-D3D12 driver (`dzn`) is not packaged
by Debian, and building it is the one remaining route to a hardware-backed
**Vulkan** ICD.

### 7.6 Design R, with a device on the end

Design R selected correctly on eight distros and passed its self-test, and had
never had a driver on the end of the choice. E51 and E52 put one there. Read the
first three rows together: they run the **same** host Vulkan ICD and differ only
in how the process got a libc that can satisfy it.

| Case | Runtime | Feature | Driver | Result |
|---|---|---|---|---|
| E31 | bundled | off | host lavapipe | no devices |
| E32 | bundled | on | host lavapipe | 1 device (the shim half) |
| E51 | **host** | none at all | host lavapipe | 1 device (the Design R half) |
| E52 | **host** | none at all | NVIDIA `libcuda.so.1` | the round trip, on the RTX 3050 Ti |

The switch is forced with `CROSS_LIBC_DLOPEN_RUNTIME=host`. Auto declines on this host
and is right to: the bundled glibc 2.44 is newer than the host's 2.41, so a
switch could only lose, and that is the rule E17 measures. What E51 and E52
measure is whether the switched runtime can drive a real device, not whether it
should have been chosen.

The two halves of the design are now each demonstrated end to end, on the same
host, against the same driver, and they remain independent: on a musl host only
the shim half exists, which is why the musl row of the matrix has no escape
hatch (risk 4).

---

---

[REPORT index](README.md) | [previous](06-goal-2-the-last-blocker.md) | [next](08-test-results.md)
