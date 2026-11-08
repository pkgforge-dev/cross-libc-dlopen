# musl-crypt

Provenance and licence for the vendored sources in this directory.

## Where they came from

musl v1.2.5, `src/crypt/` and `include/crypt.h`:

```
https://git.musl-libc.org/cgit/musl/tree/src/crypt?h=v1.2.5
https://git.musl-libc.org/cgit/musl/tree/include/crypt.h?h=v1.2.5
```

## What was changed

Two include lines, and nothing else. `crypt.c` and `crypt_r.c` include
`"crypt.h"` rather than `<crypt.h>`, so the build uses the header beside them
instead of whatever the floor image happens to ship. `crypt_des.c` and
`encrypt.c` are unchanged and still include `"crypt_des.h"`.

`compat.h` supplies the two macros musl's own build defines and a glibc build
does not: `hidden` and `weak_alias`. The rename from musl's public entry points
to the `musl_` names happens at compile time, in `src/Makefile`, so these files
stay byte-identical to upstream.

## Why they are here

`src/crypt-shim.c` carries the argument. In short: musl keeps `crypt`,
`crypt_r`, `encrypt` and `setkey` inside `libc.so`, so a musl-built host object
imports them with no `DT_NEEDED` on anything, and glibc keeps them in
`libcrypt.so.1`, which a musl host does not ship.

## Licence

musl as a whole is MIT. `crypt_des.c` is BSD-3 (FreeSec, David Burren and
Solar Designer). `crypt_md5.c`, `crypt_sha256.c` and `crypt_sha512.c` are public
domain, and `crypt_blowfish.c` is public domain with a permissive fallback.
Each file carries its own notice. `LICENSE` beside this file reproduces the two
that require it, because BSD-3's binary-distribution clause requires the notice
to travel with the binary.
