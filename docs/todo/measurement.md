# Measurement

Entries whose deliverable is a number that does not exist yet.

---

## T-01 Static and mostly-static binaries: which of the three actually work

- **Source.** The port brief, task 4.2. Written down as three distinct
  questions because "static binaries cannot `dlopen`" is close enough to true to
  be repeated and wrong in the way that matters.
- **Category** measurement, **Priority** high, **Effort** medium,
  **Status** open
- **Problem.** [`docs/limits.md`](../limits.md) states three cases and
  labels all three UNVERIFIED. A user linking a portable release binary has no
  answer.
- **Premise**, and how far it was checked: **read, not measured.** The three
  cases and what is believed about each are the static rows in
  [`docs/limits.md`](../limits.md), which is where they are stated and
  where the closure rewrites them. ⚠ Nothing there was confirmed against a
  specific musl or glibc version.
- **Approach.** ⚠ The suspected blocker is **not** `dlopen`: it is that a
  fully static binary has no `LD_PRELOAD` mechanism, because there is no
  dynamic loader to honour it. Measure that first; if the preload cannot be
  delivered, the `dlopen` question is moot for case 2 and the answer is about
  delivery, not about libc.
- **Prove.**
  ```bash
  sh scripts/run-evidence.sh   # after adding a stage that links all three shapes
  ```
  ⛔ Write down which of the three was measured, on what, and what happened. An
  "N/A" without a measurement behind it is the mistake
  [`../report/10-measured-versus-assumed.md`](../report/10-measured-versus-assumed.md) section 10's last entry is about.

---

## T-02 `libepoxy.so.0`, and the eight loaders behind it

- **Source.** `tools/plugin_boundaries.py --check` against the gtk4 AppDir.
- **Category** measurement, **Priority** high, **Effort** low,
  **Status** open
- **Problem.** The tool reports nine UNCLASSIFIED loaders in that AppDir. One of
  them is `libepoxy.so.0`, which is **itself a GL entry-point loader**: it
  `dlopen`s `libGL`/`libEGL`/`libGLESv2` by soname and resolves through them.
  That is the same DISPATCHER shape as libglvnd, and it is very likely why the
  gtk4 demo's measured call counts split the way they do (E83).
- **Premise.** Measured, by running the tool. The classification of `libepoxy`
  as a dispatcher is **inferred from its API**, not yet measured in a process.
- **Approach.** `libepoxy.so.0` first, then the other eight.
- ⛔ **Do not assume it is benign because GTK4 rendered.** `libdecor-0.so.0` was
  benign; `libGLX.so.0` was the whole of [`../report/09-the-second-boundary.md`](../report/09-the-second-boundary.md)
  section 9.
- **Prove.**
  ```bash
  python3 tools/plugin_boundaries.py .tmp/gtk4x/AppDir --check
  ```
  Closes when `UNCLASSIFIED` reaches 0, each of the nine having been classified
  by measurement rather than by reading its header.

---

## T-03 A second consumer, measured end to end

- **Source.** The port brief, task 1.5.2. ⛔ Blocking on the README's opening
  sentence.
- **Category** measurement, **Priority** high, **Effort** medium,
  **Status** partially done
- **Where it stands.** [`../../examples/plain-preload/`](../../examples/plain-preload/)
- **Problem.** Every measured result in the record was obtained through an
  AppImage. "Standalone" is therefore a claim about a case nobody has run.
- **Premise.** The code no longer *requires* an AppDir: `CROSS_LIBC_DLOPEN_ROOT`
  joins `APPDIR`, the library directory is configurable, and the marker file is
  optional. Measured by construction (the code reads that way), **not** by a
  run against a real host driver with no AppDir anywhere.
- **Approach.** `examples/plain-preload/` is the shape. What it does not yet
  have is a **host GPU driver** on the far end rather than a stand-in library.
- ⚠ **Until that exists, the README's opening sentence stays about AppImages.**
  Widening it to "any program" before there is a measured non-AppImage run
  against a real driver would be exactly the move this project's whole standard
  exists to prevent. Build it, measure it, then rewrite the sentence, in that
  order.
- **Prove.**
  ```bash
  sh examples/plain-preload/run.sh
  ```
  Closes when that script prints a before and an after against a **host GPU
  driver**, on a host whose libc differs from the process's.

---

## T-04 Two struct sizes where this project and solo disagree

- **Source.** Reference sweep of `pg83/solo`, [`../history/references/solo-findings.md`](../history/references/solo-findings.md) F2.
- **Category** measurement, **Priority** medium, **Effort** low,
  **Status** open
- **Problem.** solo's `dev/abi-diff.txt` lists `struct_rusage` as 144 bytes on
  glibc and 272 on musl, and `struct_sched_param` as 4 versus 48, both marked
  DIFF. This project measured both as **crossing harmlessly** (E47, E49).
- **Premise.** Both measurements are real; they are very likely answering
  different questions. solo probes `sizeof`; `tests/abi-host.c` probes whether
  the **fields it actually uses** sit at the same offsets, which they can while
  the totals differ. ⚠ **"Very likely" is not a measurement.**
- **Approach.** Extend `tests/abi-host.c` to report `sizeof` alongside the
  per-field offsets, so the two projects' numbers are comparable rather than
  merely reconcilable in prose.
- **Prove.** `sh scripts/run-appimage.sh --only alpine`, with E47/E49 printing
  both figures. Closes when the disagreement is either explained by the
  measurement or is a finding.

---

## T-05 NixOS as a host class

- **Source.** Reference sweep of `pg83/solo`, F7, and solo's
  [issue #2](https://github.com/pg83/solo/issues/2).
- **Category** measurement, **Priority** medium, **Effort** medium,
  **Status** open
- **Problem.** The host matrix here is Alpine, Debian trixie, Ubuntu 14.04 and
  16.04. NixOS is a fourth host class that neither is nor pretends to be FHS,
  and nothing here has run on it.
- **Premise.** Measured, in solo's tracker rather than here: NixOS publishes
  Vulkan ICD manifests under `/run/opengl-driver/share`, and **no FHS path
  carries a manifest at all**. A user hit `vkCreateInstance failed: VkResult -9`
  ⚠ That is the same result code this project's E31 predicts, from a different cause.
  This project's sharun path already names `/run/opengl-driver/lib`; the
  **manifest** directory is a different thing and is unhandled.
- **Approach.** Add a NixOS host stage. ⭐ **Lay the tree out and then delete
  `/usr/share/vulkan`, `/usr/local/share/vulkan` and `/etc/vulkan`**, so no FHS
  path can satisfy the case by accident. That is solo's technique and it is what
  makes the pass mean something.
- **Prove.** A stage reporting MATCH on a NixOS layout with the FHS paths
  removed.

---

## T-06 Translate the two live struct hazards at the call

- **Source.** Reference sweep of `pg83/solo`, at
  [`../history/references/solo-usable.md`](../history/references/solo-usable.md) section 1.
- **Category** measurement, **Priority** high, **Effort** medium,
  **Status** open
- **Problem.** [`docs/limits.md`](../limits.md) states the two live
  hazards are not fixable, and gives the reason as "an offset compiled into an
  object is not reachable from a preload".
- **Premise.** ⛔ **The measurement is right and the reason is imprecise.** It
  holds for a preload that interposes only `dlopen`. solo repairs both by
  interposing the **call** (`lib/glibc_shim.cpp:3092` for `regexec` and
  `:3460` for `nftw`), so the reach is a property of where you interpose, not of
  preloading.
- **Approach.** Interpose `regexec` and `nftw`, translating at the boundary.
  The shapes and the direction of each translation are quoted in
  `solo-usable.md` section 1.
- ⚠ **Interpose only where the direction is unambiguous.** solo knows which
  side every call came from because it supplies the whole libc; this does not,
  and translating a call that needed no translation is a new defect of the same
  family.
- **Prove.**
  ```bash
  sh scripts/run-appimage.sh --only alpine
  ```
  E50 currently reports `2 live hazard(s)`. Closes when it reports 0 **and**
  E47/E49 still pass: a translation that breaks the same-libc control is not a
  fix.

---

## T-07 `crypt(3)` for a musl-built host object

- **Source.** The PPSSPP report of a `libcrypt.so.1` probe at startup,
  [hrydgard/ppsspp#22988](https://github.com/hrydgard/ppsspp/issues/22988),
  and the measurement that followed it.
- **Category** measurement, **Priority** high, **Effort** medium,
  **Status** done
- **Problem.** `cld_global_scope_libs[]` loaded `libcrypt.so.1` so that a
  musl-built host object's `crypt` reference would resolve after its libc edge
  was dropped. glibc keeps those names in `libcrypt.so.1`, which is a separate
  package: Alpine ships no such file at all, and a bundle need not carry one.
  The probe therefore failed on the host it was written for, and on a host that
  did have one it loaded a host glibc DSO into the global scope.
- **Premise.** Measured, not assumed. A musl-built object importing `crypt`
  and `crypt_r` fails to load with `undefined symbol: crypt` when no libcrypt
  is present. When a bundled `libcrypt.so.1` is present the same object binds
  to it instead, and that is worse: musl's `struct crypt_data` is 260 bytes and
  libxcrypt's is 32768, so the call writes past the caller's buffer (measured:
  SIGSEGV, exit 139).

  ⚠ **Three sizes are in the wild, not two.** glibc's own `libcrypt.so.1`,
  which every host at or below glibc 2.27 ships, has a **131232**-byte struct:
  a keyschedule plus four 32768-byte DES tables. Scratch sized for libxcrypt
  is 128 KiB too small for it, and its DES path populates all four tables
  (measured on glibc 2.24: SIGSEGV). The first version of this fix made that
  mistake on the other side of the same bug.
- **Approach.** Vendor musl's crypt implementation under `src/musl-crypt/` and
  define the four names in `src/crypt-shim.c`. Prefer a real libcrypt when the
  process has one, because musl has no yescrypt (`$y$`) or scrypt (`$7$`) and
  treats an unrecognised salt as DES. `crypt_r` gives the real implementation
  scratch of its own, sized for the largest of the three and held in
  thread-local storage rather than on the stack, then copies back only the
  result string, because the caller's struct size cannot be recovered.

  ⚠ **The real implementation is found through `dlsym(RTLD_NEXT)`.** Two other
  resolutions were tried and both are wrong here. `RTLD_DEFAULT` starts at the
  front of the global scope, which contains this preload, so it returns our own
  `crypt_r`, the self-check rejects it, and the caller silently gets musl
  instead of the libcrypt the application links: measured as E109 falling back
  to a DES hash for a `$y$` salt. Skipping one match is not enough, because the
  application's libcrypt may be after the preload in the same loop. `RTLD_NEXT`
  begins the search at the next object, which is what forwarding means.

  ⚠ **What still does not work, and is not fixed:** a plugin that `DT_NEED`s
  libcrypt and is loaded `RTLD_LOCAL` keeps it out of the global scope, so
  neither `RTLD_NEXT` nor `RTLD_DEFAULT` can reach it. The plugin's own
  versioned `crypt@XCRYPT_2.0` reference still binds to this preload, so it
  calls us, we find nothing, and it gets musl's answer. Measured: `$y$`
  returns `$yz8eIFW3uJoo` instead of the `$y$j9T$...` hash, which is a wrong
  password rather than a miss. Reaching the plugin's private libcrypt needs
  its handle, which this object does not have.
- **Prove.**
  ```bash
  sh scripts/run-evidence.sh
  ```
  E108 fails before the change and passes after; E109 is the control that the
  forwarding did not replace a working libcrypt. Measured:

  ```
  E108   MATCH predicted=OK    OK: musl_crypt_r_call()=42
  E109   MATCH predicted=OK    $y$j9T$saltsalt$0ZRt7zd0gn9pQsq3yDeuwj9hFSoqeo/y42wyzM0m.d0
  predictions matched: 72   mismatched: 0
  ```

  ⚠ **E107 does not fail before the change in the image the suite runs it, and
  an earlier version of this entry said it did.** The stage-3 image carries
  `libcrypt1`, so `main`'s `cld_global_scope_libs[]` load of `libcrypt.so.1`
  satisfies the bare `crypt` reference and E107 passes both ways there.
  Measured on `main` (586e61b) in that image: E107 `OK` exit 0, E108
  `Segmentation fault` exit 139. The `dlopen FAILED: libc.musl-x86_64.so.1`
  line quoted here before was a measurement on a host with no libcrypt at all,
  which is a different machine from the one the case runs on. E107 stays in the
  table because it covers that host, and the stage-3 comment now says which of
  the two separates the branch from `main`.

