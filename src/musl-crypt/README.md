# musl-crypt

Provenance and licence for the vendored sources in this directory.

## Where they came from

musl v1.2.5, `src/crypt/` and `include/crypt.h`:

```
https://git.musl-libc.org/cgit/musl/tree/src/crypt?h=v1.2.5
https://git.musl-libc.org/cgit/musl/tree/include/crypt.h?h=v1.2.5
```

## What was changed

Three things differ from upstream, and no line of algorithm code is touched.

`crypt.c` and `crypt_r.c` include `"crypt.h"` rather than `<crypt.h>`, so the
build uses the header beside them instead of whatever the floor image happens
to ship. `crypt.h` is musl's own, with a different include guard and a header
comment saying why it is here, because the floor image has no libcrypt
development package. The other seven files are byte-identical to musl v1.2.5.

`compat.h` supplies the two macros musl's own build defines and a glibc build
does not: `hidden` and `weak_alias`. The rename from musl's public entry points
to the `musl_` names happens at compile time, in `src/Makefile`, as does the
`-fvisibility=hidden` that keeps those names out of the preload's export
table.

## Why they are here

`src/crypt-shim.c` carries the argument. In short: musl keeps `crypt`,
`crypt_r`, `encrypt` and `setkey` inside `libc.so`, so a musl-built host object
imports them with no `DT_NEEDED` on anything, and glibc keeps them in
`libcrypt.so.1`, which a musl host does not ship.

## Licence

`crypt_des.c` is BSD-3 (FreeSec, David Burren and Solar Designer), and
`crypt_md5.c` is BSD-2 (Poul-Henning Kamp, on the MD5 block itself).
`crypt_sha256.c`, `crypt_sha512.c` and `crypt_blowfish.c` are public domain.
`crypt.c`, `crypt_r.c` and `encrypt.c` carry no notice of their own and fall
under musl's MIT.

`LICENSE` beside this file reproduces the three that require it, because both
BSD licences make the notice travel with a binary distribution. It is packed as
`LICENSE.musl-crypt` beside the artefacts for that reason.
