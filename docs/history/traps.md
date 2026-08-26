# Traps

Things that cost somebody real time, each paid for once already. Several
of them are why a line in `experiments/*.sh` looks odd; changing that line
to look tidier is how the time gets paid again.

*Moved verbatim from `CONTINUE.md` when that file was dissolved into the
work record. The wording is the original: a trap written down in one
sentence is a trap the next person does not walk into.*

## 5. Things that will waste your time

Each of these cost real time here. They are recorded so they cost you none.

### 5.0 How a whole gap hid for a session, and what to do about it

This one is not a technique, it is the reason the previous handover was wrong,
and it will happen again in a different place unless you know its shape.

`glxgears` on Alpine was recorded like this:

```
E38  SKIPPED  no libGLX_<vendor>.so.0 on this host; its Mesa is not libglvnd,
              so the bundled libglvnd has no vendor to dlopen
```

with the README adding: *no loader shim can supply a file the distribution does
not ship.* The skip reason was measured and correct. The sentence after it was
neither, and it turned the whole thing into a closed question for a session. It
is now closed the other way: a shim cannot supply the missing file, but it can
replace the object that was looking for it, and section 9 of ../report/README.md is the
whole chain.

Four habits come out of that, in descending order of how much they would have
helped:

- **A SKIP names a missing capability and stops.** It may say "this host has no
  X". It may not say "and therefore nothing can be done", because that is a
  claim about the design space, it needs its own evidence, and welded to a
  measured fact it inherits the measured fact's authority. Every "not fixable",
  "cannot be", "no ... can" in a skip reason or a "what is not done" entry is a
  separate claim; go and look for the one you wrote last.
- **Scope by the user's outcome, not by your mechanism.** "This project fixes
  libc mismatches" made "host packaging, not libc" a reason to stop. The person
  running the AppImage does not know which side of that line their black screen
  is on. The two gaps in section 1 both produce the same symptom and only one of
  them is about libc.
- **Enumerate the class, do not wait to think of the members.** The gap needed
  someone to *wonder* whether libglvnd was a loader. `tools/plugin_boundaries.py`
  replaces the wondering with a measurement: a bundled object that imports
  `dlopen` is a loader by construction, and E59 fails the suite on one that is
  not classified. It immediately found `libdecor-0.so.0`, which nobody had
  looked at. Do this for the next class rather than trusting the next reader to
  be more imaginative.
- **Check whether the thing you handed off has landed.** The sharun patch sat
  under "blocked: a human must give this to a maintainer" while the fix had
  already been merged upstream. `gh api repos/<owner>/<repo>/commits/<sha>` is
  ten seconds.

And one that applies to the claim itself: **a closure claim must be stated in
terms of the outcome and must list what it did not examine.** "The experiment is
closed" was true of *can a bundled glibc drive a foreign-libc driver* and false
of *does the AppImage work on this host*. Section 4 is written that way now.

⭐ **Two more from the session that closed 4.0, both the same shape.**

- **A synthetic case cannot find what nobody thought of; a real one does not
  have to.** Four purpose-built cases, two host classes and 3470 generated
  trampolines never noticed that `gl-fwd` asked only whether the HOST had a
  vendor library. A real GTK4 application found it on its first run, because a
  self-contained AppImage is a SHAPE nothing here had ever been pointed at
  (B6). The enumeration habit above -- "a bundled object that imports `dlopen`
  is a loader by construction" -- has a partner: **enumerate the shapes of
  input, not only the classes of host.** The AppDir this repository tests
  against bundles a dispatcher and no Mesa. Most AppImages are the other kind.
- **A control that cannot fail is not a control.** E78 and E79 run the probes
  natively so E64 and E66 can be predicted against the host rather than against
  a constant, and as first written they scored `verdict <id> 1` -- MATCH,
  unconditionally. That is worse than not scoring them: if the native probe
  fails to *run*, the prediction it feeds relaxes to FAIL, and a completely
  broken shim then scores MATCH for failing too. They now assert that the
  control produced a verdict line AND that its exit status agrees with it.
  ⛔ Before adding a case that computes its own verdict, ask what input would
  make it print MISMATCH. If there is none, it is a `printf`.

### About symbol versions

- **An unversioned reference does NOT get the default definition.** This is the
  whole bug. `pthread_cond_init`, `realpath`, `regexec`, `glob`, `nftw`,
  `sched_getaffinity` and about 27 others have an obsolete definition glibc
  still exports, and a stripped or musl-built object lands on it silently.
  `tools/version_traps.py <libc>` prints the current list for any libc.
- **`dlsym` is not a way to find the default definition.** Measured in E27:
  `dlsym(RTLD_NEXT, "pthread_cond_init")` returns the **obsolete** definition on
  glibc 2.31 and the default one on 2.41. `dlsym(RTLD_DEFAULT, ...)` gets it
  right on both, but from inside the preload it finds the preload's own
  forwarder and recurses. Read the version name out of the ELF and use `dlvsym`.
- **Multi-versioned does not mean dangerous.** glibc 2.34's libpthread merge
  re-versioned 191 symbols in place: same address, two labels, either is
  correct. Only a name whose versions have **different `st_value`** is a trap.
  A list built from "has two versions" is 191 false positives long.

### About preloads, and driving the loader by hand

- **`ld.so --preload A --preload B` loads only B.** glibc's option parser keeps
  a single `preloadarg`, so a second `--preload` REPLACES the first rather than
  appending. The command line reads as if both are loaded, the process has one,
  and here that made `cross-libc-dlopen.so` silently vanish while every debug line
  it would have printed simply did not appear. `--preload "A B"` -- one flag,
  space-separated -- is the working form. `LD_PRELOAD` uses `:` and appends
  normally; this trap is specific to the flag.
- **Preload constructors run in REVERSE of the list.** Listing `gl-fwd.so`
  after `cross-libc-dlopen.so` in `.preload` runs `gl-fwd`'s constructor FIRST.
  E56 and E57 measure it both ways. Never order two preloads by writing them in
  the order you want them initialised; have the later one ask (that is what
  `cross_libc_dlopen_init_now()` is).
- **A `timeout` on a program that never exits hangs a `$( )` capture, and it
  hangs on the case that WORKED.** `timeout 25 xvfb-run ... glxgears` kills
  `xvfb-run`, the shell script, and leaves `Xvfb` and `glxgears` holding the
  stdout pipe; the command substitution then waits for a writer that will never
  close. The case that FAILS exits immediately and returns fine. Write to a file
  and `pkill` afterwards. This cost two full container runs before it was even
  visible as a harness bug rather than a hang in the shim.

### About the test environment

- **`.tmp/AppDir` is shared state, and debugging one host by hand poisons the
  next full run.** Section J rewrites `.preload`; so does anyone reproducing a
  case at the prompt. The next `appimage.ps1` then runs sections A through I
  with GL shims those cases know nothing about, and what you get is not a
  crash: E53 and E53b failed on hardware that was working and E59 counted
  nineteen bundled loaders where the AppImage ships eight. `40-appimage.sh` now
  resets `.preload` and removes the shims before anything runs, and refuses to
  start if `shared/bin` holds a file the AppImage does not ship. If you are
  debugging by hand, `rm -rf .tmp/AppDir` afterwards.
- **`podman run --platform linux/arm64 <tag>` REPLACES the cached image for
  that tag.** The pull is per-tag, not per-tag-per-arch, so one aarch64 probe
  left `alpine:3.22` resolving to arm64 and the next suite run died with
  `exec container process: Exec format error` on an image it had used all day.
  `podman pull --platform linux/amd64 <tag>` puts it back. To run aarch64 code,
  name `qemu-aarch64-static` instead -- section P does, and it also avoids
  registering a binfmt handler, which is a kernel-wide setting.
- **Ubuntu 14.04 and 16.04 are NOT on `old-releases.ubuntu.com`.** As of
  2026-08 that host jumps straight from `saucy` to `utopic`; every
  `dists/trusty/...` and `dists/xenial/...` path 404s. Both releases are still
  inside their ESM window and are still served from **`archive.ubuntu.com` at
  the default path**, so the `sources.list` rewrite that every guide prescribes
  is what breaks them. What does have to go is the image's own ESM source,
  which points at `esm.ubuntu.com` and needs credentials: apt fails the whole
  update over it and then reports every package as "unable to locate", which
  reads exactly like a dead mirror. `rm -f /etc/apt/sources.list.d/*esm*`.
- **Handing sharun the host's library directories changes what the NO-SHIM
  controls do.** With `/etc/ld.so.conf`'s directories on
  `SHARUN_FALLBACK_LIBRARY_PATH`, `glxgears` renders on Alpine with no GL shim
  at all -- through the X server's own softpipe GLX -- and E61 stops being a
  control for anything. Add host directories only where a measurement showed
  they are needed, and print that they were added.

- **Debian's Vulkan ICD manifest names a bare soname, not a path.**
  `cross-libc-dlopen` only ever intercepts absolute paths, so on Debian the whole
  feature is a no-op and every A/B looks identical and healthy. Alpine and
  Gentoo use absolute paths. Write your own manifest if you want the code path.
- **`xvfb-run -a` alone gives you an X server with no GLX.** `glxgears` then
  says `couldn't get an RGB, Double-buffered visual`, which reads exactly like a
  driver failure. You need
  `-s '-screen 0 1024x768x24 +extension GLX +extension RANDR +render'`.
- **Alpine's `mesa-gl` is not libglvnd.** There is no `libGLX_mesa.so.0` on
  Alpine, so anything bundling libglvnd has no vendor library to load. That is
  not fixable from a loader shim.
- **`CROSS_LIBC_DLOPEN=0` is not always a clean control.** Under the
  demo AppImage's own AppRun on Alpine, with a search path that reaches `/lib`,
  the bundled glibc `ld.so` finds `libc.musl-x86_64.so.1` and loads it: the
  process ends up with **two libc families initialised** and renders anyway.
  `LD_DEBUG=libs` and `grep 'calling init:'` is what distinguishes an object
  that was *searched for* from one that was *loaded*.
- **`/bin/true` is not always an ELF binary.** On Rocky 9 it is a 51-byte shell
  script, and `ld.so` answers `file too short`, which looks exactly like a
  broken runtime and is not. `runtime-select` re-execs itself instead.
- **`/proc/self/exe` is the loader, not you**, when a program is started as
  `ld-linux.so --library-path ... ./prog`. The kernel exec'd the loader. Use
  `argv[0]`. This produced a false `SELF-TEST FAILED` on every newer host.

### About writing the tests themselves

- **`tests/vkprobe.c` used to smash its own stack on SUCCESS.** Its `struct
  Props` was ~800 bytes shorter than `VkPhysicalDeviceProperties`, so the driver
  wrote past it every time enumeration *worked*. A segfault that only happens
  when things go right is the most misleading result available. It now has the
  tail, a guard band, and a check.
- **stdout is block-buffered when it is a pipe.** A probe that crashes loses
  every line it printed, and you conclude it crashed at the start. `setvbuf(...,
  _IONBF, ...)`.
- **A verdict computed inside `$( )` increments the counter in a subshell.** The
  per-line verdicts and the totals then disagree, and the suite reports success
  while showing a MISMATCH.
- **`ls a b` fails as a whole when either glob misses.** Used as a capability
  probe, that silently skips a case on a host that could have run it.
- **A verdict grep that matches inside another word is a silent wrong answer.**
  `grep -E 'OK|FAILED|rror'` over a probe's output matches `glGetError` and
  reports the diagnostic line as the verdict. Take the probe's own
  `^(OK|FAILED)` line FIRST and only then fall back to something looser -- the
  same two-pass shape `summarise()` already uses, for the same reason.
- **A probe that prints `GL_RENDERER` has not finished.** A GL shim exporting a
  subset gets a context, prints a renderer, and dies on the next call. Any test
  whose success condition is "a renderer appeared" passes such a shim. Make the
  probe do something whose RESULT you check -- `glprobe` clears to a known
  colour and reads the pixel back -- because a stub that returns zero and a
  driver that cleared the buffer are otherwise identical from outside.
- **Predicting `FAIL` scores a segfault as a MISMATCH.** "It did not work"
  arrives as an error code, a refusal to load, or a crash. Normalise first, then
  predict.
- **`dlerror()` is destructive, and so is anything that calls `dlsym`.** Reading
  it to log it consumes it. Less obviously: a diagnostic that probes with
  `dlsym` replaces the pending message with its own last miss, so the caller is
  told the wrong object failed. Both were live bugs here.
- **`mkstemp` rewrites its template in place.** Reusing a spent template makes
  the second loop a silent no-op. This made a fuzz test "pass" nothing.
- **glibc serves a 16 KB `malloc` from its arena; musl `mmap`s it.** So an
  absent `mmap` in an `strace` comparison proves nothing about whether the
  allocation happened. Compare on syscalls that must appear in both, such as
  `openat` of a specific file.
- **`RTLD_DEFAULT` does not see an object's own dependencies.** A "missing
  symbol" report that only consults the global scope accuses a library of
  missing 446 symbols its own `DT_NEEDED` closure supplies.
- **glibc puts version *names* in `.dynsym`** as zero-sized `SHN_ABS` entries
  (`GLIBC_2.32`, `GLIBC_ABI_DT_RELR`). They are ABI markers, not API. A
  generator that treats them as symbols emits C identifiers containing a dot.
- **Run every runtime test twice**, `CROSS_LIBC_DLOPEN=0` then `=1`. A
  single-sided result cannot distinguish "the fix worked" from "it was already
  falling back to something else".
- **Shell scripts must be LF.** A CR becomes `$'...\r'` and yields baffling
  "not found" errors. `.gitattributes` enforces it and `run.ps1` verifies rather
  than trusts.
- **`podman machine ssh` drops a file called `NUL` in your working directory.**
  It writes its known_hosts entry to the Windows null device, and from Git Bash
  that resolves to a real file. `git add` then fails the whole commit with
  `short read while indexing NUL`, which reads like repository corruption and is
  a stray 99-byte SSH host key. `rm -f ./NUL` clears it. Check for it after any
  `podman machine ssh`.
- **PowerShell corrupts a string piped to a native process.** Mount scripts into
  the container instead. A PowerShell function that leaves native output on the
  success stream returns an array, not your exit code.
- **`& $exe @array 'x' 'a','b','c'` passes the comma list as ONE argument.**
  PowerShell parses `a, b, c` in a command position as an array expression and
  stringifies it. The GPU-capability probe did this and reported "no GPU" on a
  machine that has two, and the whole suite then SKIPPED nine cases while
  looking perfectly healthy. Build one flat array and splat it once.

### About reaching the GPU

- **A missing library directory does not announce itself as a missing library.**
  This is the single most misleading failure here. `libcuda.so.1` loads,
  resolves every entry point, and then `cuInit` returns 100
  `CUDA_ERROR_NO_DEVICE` -- because it `dlopen`ed `libdxcore.so` by bare soname
  and `ld.so` could not find it. Mesa's `d3d12_dri.so` does the same with
  `libd3d12.so` and the user sees `Error: glXCreateContext failed`. Both read as
  hardware faults. `LD_DEBUG=libs` plus `grep 'find library='` is the one
  command that distinguishes them.
- **`sharun` re-execs and replaces your `--library-path`.** Running
  `$APPDIR/bin/<prog>` under `ld.so --library-path ...` does not do what it
  looks like: everything in `bin/` is sharun, which re-execs the real binary
  with a path it assembles itself. The trace shows two pids and only the second
  one matters. `SHARUN_FALLBACK_LIBRARY_PATH` is the supported way to add to it
  without editing anything.
- **`MESA_D3D12_DEFAULT_ADAPTER_NAME` is the only adapter selector.** Without it
  a machine with two GPUs quietly gives you the integrated one. `GALLIUM_DRIVER=d3d12`
  is what selects the driver; `MESA_LOADER_DRIVER_OVERRIDE=d3d12` alone is not
  enough and falls back to llvmpipe without saying so.
- **`glxgears -info` prints the whole `GL_EXTENSIONS` string**, which is several
  kilobytes on one line and will bury whatever you were reading. Grep for
  `GL_RENDERER` with `-m1`.

### About measuring what the loader did

- **`LD_DEBUG=bindings` prints the version a reference ASKED for, not the one it
  got.** For the version-binding trap that is exactly the wrong half: an
  unversioned reference asks for nothing, and the line is silent about which of
  the two definitions it landed on. `tests/bindprobe.c` reads the slot instead.
- **A lazily-bound GOT slot still holds the PLT resolver stub.** Reading it
  without `LD_BIND_NOW=1` measures the stub, not the definition. Eager binding
  changes *when* the choice is made, never which definition is chosen.
- **A `d_ptr` in a mapped `PT_DYNAMIC` may be absolute or link-time**, depending
  on the port, and dereferencing the wrong guess is a segfault. `dladdr` decides
  it safely: it searches the loaded objects for an address and never
  dereferences it, so the candidate that lands inside that object is the right
  one.
- **Taking `&func` in an EXECUTABLE gives you its own PLT entry**, not libc's
  address, so comparing that against a shared object's `&func` can differ for a
  linking reason rather than a libc one. Compare the FILE each address lands in.

### About what a control is allowed to do

- **Some controls do not flip, and that is the result.** The CUDA cases were
  written expecting the feature-off control to fail. It passes, because NVIDIA
  ships against a `GLIBC_2.2.5` floor and nothing in the blob can be missing.
  The correct response was to state that as the finding (../report/07-closed-source-driver-and-abi.md 7.1), not to
  keep forcing the test until it broke. A control that has to be engineered into
  failing is not evidence of anything.
- **`$?` after a pipeline is the LAST command's status.** `probe | sed` then
  `echo $?` reports `sed`. Same family as the subshell-counter bug above, and it
  made three scratch runs look like they all succeeded.
