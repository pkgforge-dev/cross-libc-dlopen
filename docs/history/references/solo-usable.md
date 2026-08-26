# What transfers from `pg83/solo`

The lessons and the actual lines. ⭐ **This is the file to read before touching
the ABI bridge or the corpus test** -- it exists so the next session does not
have to re-clone.

Reference commit: `79451211e2b7833f423b07bdb8a6c5584abf5822`.
The reasoning behind each item is in [`solo-findings.md`](solo-findings.md).

---

## 1. Two "unfixable" struct hazards are fixable at the CALL

`docs/limits.md` says an offset compiled into an object is not reachable from a
preload. That is true of a preload that interposes only `dlopen`. It is **false
of one that interposes the call**, and solo does exactly that.

**`regmatch_t` -- glibc 8 bytes, musl 16.** solo declares the foreign shape and
translates:

```cpp
// lib/glibc_shim.cpp:3029
// glibc regmatch_t holds int offsets while musl's are 64-bit

struct GlibcRegmatch { ... };                        // :3069

static int sh_regexec(const GlibcRegex* compiled, const char* string,
                      size_t nmatch, GlibcRegmatch* pmatch, int eflags) {
    regmatch_t buffer[16];                            // :3093  native shape
    regmatch_t* matches = buffer;
    if (nmatch > 16)
        matches = (regmatch_t*)calloc(nmatch, sizeof(regmatch_t));
    int result = regexec(compiled->shadow, string, nmatch, matches, eflags);
    /* ... copy back into the GUEST's shape ... */
}
```

**`FTW_*` -- musl's codes are glibc's plus one.** One subtraction, in a
trampoline that stands between the two:

```cpp
// lib/glibc_shim.cpp:3456
// musl's FTW_* type codes are glibc's plus one (dev/abi-diff.txt), so the ...

static int sh_nftw_trampoline(const char* path, const struct stat* status,
                              int type, struct FTW* info) {   // :3460
    return reinterpret_cast<NftwCallback>(*ThreadTls::current()->nftwCallback())
               (path, status, type - 1, info);
}
```

⭐ **What to do here.** Both are narrow: interpose `regexec` and `nftw` in
`src/forward-shim.c`'s neighbourhood, translate at the boundary, and prove it
with the existing E50 probe running green instead of reporting two live
hazards. It is a bounded piece of work, not an architecture change.

⚠ **What NOT to do.** Do not conclude that everything solo's bridge covers is
reachable this way. solo supplies the whole libc and knows which side every call
came from; a `dlopen` interposer does not, and guessing wrong translates a call
that did not need it. Interpose only where the direction is unambiguous.

Work: [`docs/todo/measurement.md`](../../todo/measurement.md) T-06.

---

## 2. Probe the whole ABI surface, print the matches too

`dev/abi_probe.c` + `dev/abi_diff.py` -> `dev/abi-diff.txt`, 418 lines, first
line:

```
abi probe: 396 ok, 18 DIFF, 2 glibc-only, 0 musl-only
           probe                                               glibc         musl
DIFF       size regmatch_t                                         8           16
DIFF       value FTW_D                                             1            2
...
ok         offset dirent_d_name                                   19           19
```

⭐ **The `ok` rows are the point.** "We checked 396 things and they matched" is a
claim; an absence of rows is not. This project's E50 checks six and reports two.

The file is checked in and CI re-runs the generator (`abi_diff` step in
`.github/workflows/ci.yml`, `ubuntu-clang` job), so a libc update that moves an
offset shows up as a diff on a tracked file rather than as a bug months later.

Work: [`docs/todo/measurement.md`](../../todo/measurement.md) T-04.

---

## 3. Corpus: one library, one fresh process, per-symbol coverage

`tst/corpus.py`, whose own docstring is the design:

> `load` handles one package: the package's own libraries are loaded eagerly in
> a fresh process each, with the declared dependency packages extracted next to
> them, and the per-library results land in a JSON file.

The loader body is nine lines (`tst/corpus_load.cpp`): `stub_dlopen(argv[1],
RTLD_NOW | RTLD_LOCAL)`, non-zero on failure, with a fault handler installed
first so a crash is a report rather than a silence.

Three properties this project's `tests/corpus.c` does not have:

| property | why it matters |
|---|---|
| **a fresh process per library** | one library that corrupts the process cannot change the verdict on the next 200 |
| **`RTLD_NOW`, eagerly** | a lazy load reports success for an object whose relocations would have failed at the first call |
| **stub imports collected from the bridge's own debug output** | the merged report says which ABI entries the corpus *demands* and which of those only have stubs -- a per-symbol view, not a count |

The manifest is `tst/corpus_x86_64.json`: a dict of `packages` (**1176**
entries; aarch64 **1172**) and a `snapshot`, pinned in CI by
`hashFiles('tst/corpus_x86_64.json', 'build.py')` so the corpus is cached and
reproducible.

Work: [`docs/todo/infrastructure.md`](../../todo/infrastructure.md) T-15.

---

## 4. Delete the path that would mask the failure

solo's `nixos-lavapipe` job builds the NixOS driver layout and then removes
every FHS path that could satisfy the test by accident:

```yaml
# .github/workflows/ci.yml, nixos-lavapipe
- name: Lay out the NixOS driver tree
  run: |
    store="$(nix build --no-link --print-out-paths nixpkgs#mesa | head -1)"
    test -n "$(find "$store/share/vulkan/icd.d" -name 'lvp_icd*.json' -print -quit)"
    sudo mkdir -p /run/opengl-driver
    sudo ln -s "$store/share" /run/opengl-driver/share
    sudo rm -rf /usr/share/vulkan /usr/local/share/vulkan /etc/vulkan
```

and then asserts the rendered image by hash:

```yaml
env -u XDG_DATA_DIRS -u XDG_CONFIG_DIRS -u VK_DRIVER_FILES -u VK_ICD_FILENAMES \
  ./vulkan nixos.png
echo "9abbdcc0...  nixos.png" | sha256sum -c
```

⭐ **Two techniques, both directly applicable here.**

1. **Remove the masking path.** This repository's own standard -- a test whose
   success condition is "a renderer string appeared" passes a broken shim -- is
   the same idea one layer up. Several cases here set `VK_DRIVER_FILES` or
   `LIBGL_ALWAYS_SOFTWARE` to *force* a path; none of them deletes the
   alternative that would have worked anyway.
2. **Assert the frame by hash, with the environment stripped.** `glprobe` reads
   one pixel back. A whole-image hash is strictly stronger and costs nothing.

Work: [`docs/todo/infrastructure.md`](../../todo/infrastructure.md) T-16.

---

## 5. What does NOT transfer

⭐ **Adopt ideas, not architectures.**

| solo does | why it does not transfer |
|---|---|
| replaces the dynamic loader (`lib/elf_loader.cpp`) | solo owns the process image. This project is a guest in somebody else's, where replacing the loader means replacing the host's. Refused with a measurement in [`docs/rejected-designs.md`](../../rejected-designs.md) |
| hand-maintains a 5948-line bridge | this project's shim is **generated** from measured symbol inventories. Different maintenance model, deliberately: solo's is auditable line by line, this one cannot drift from the inventory it was generated against. ⚠ Neither is better outright -- see the comparison in `README.md` |
| bundles the entire libc | the whole premise here is *not* bundling a second libc |
| an `AT_EXECFN` bootstrap | needs to own the executable. A preload does not |

---

## ⛔ Where this write-up stops

Nothing here was measured against solo -- no build, no run. `lib/glibc_shim.cpp`
and `lib/elf_loader.cpp` were read in the regions cited and skimmed elsewhere,
and `lib/bionic_shim.cpp`, `lib/musl_tls.c`, `bin/vulkan/` and `ext/` were not
read at all. A claim about what solo does *not* cover is not made anywhere
above, because that claim would need the full read.
