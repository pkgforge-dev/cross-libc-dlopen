# What the last measuring session closed

The handover narrative from the end of the measurement phase, kept so the
closures above have the story that produced them.

*Moved verbatim from `CONTINUE.md` when that file was dissolved into the
work record. The wording is the original: a trap written down in one
sentence is a trap the next person does not walk into.*

### 4.3 What the last session closed, so you do not redo it

⭐ **Section 4.0 is closed except B7, which is hardware-blocked and says so in
one sentence.** Every closure is written under the item it closes, in 4.0.1,
with the command that proves it and the output it produced. What follows is the
shape of the session, not a substitute for reading those.

**The keystone was one instruction.** A table slot is an address, so nothing
could happen AT a call; the repair is that each trampoline now carries its own
index in a register the ABI already lets a call destroy (`%r11`, `x17`), and an
unresolved slot points at a register-saving resolver where that index is the
whole message. B1, B4 and the two counters that answer B6 all reduce to it, and
it is about sixty lines of assembly.

**Three of the eight items were answered by measuring rather than by building.**
B3 needed two container images and a corrected premise. B7 needed two `ls`
commands and the honesty to say the two properties are anti-correlated. B8
needed `qemu-aarch64-static` instead of the `--platform` flag the row suggested.

**The two most valuable results came from things that had never been run.**

- **A real application found a real bug.** gtk4-demo -- 272 bundled libraries,
  its own Mesa -- died with SIGFPE under the shims and ran fine without them,
  because `glfwd_host_has_vendor()` asked only about the host and hijacked a
  self-contained AppImage onto Alpine's Mesa. Four synthetic cases and two host
  classes had never seen an AppImage of that shape. B6.
- **A native control settled an attribution that both a maintainer and I had
  got wrong.** `eglprobe` fails on Ubuntu 16.04 with the shims -- and natively,
  with no AppImage in the process at all. E64 and E66 are now predicted against
  what the host does rather than against a constant, because the shim's claim
  is transparency and the yardstick for transparency is the host.

**Two items came from outside and are not in the original eight.** B9 is a
defect reported in a PR, and the PR's own follow-up made the better argument:
the shim's hardcoded directory list was a guess about somebody else's
packaging, it had drifted, and the repair is to read `/etc/ld.so.conf` --
which `runtime-select.c` already did, so the two now share one walk
([`src/ld-conf.h`](../../src/ld-conf.h)). B10 is a host limitation to record rather
than patch, and it is in 4.2.

**One harness lesson is worth more than any of the code.** Sections 5's new
entries are all from this session and all the same shape: a measurement that
changed something it was not supposed to change. Hand-debugging left the shims
in the shared `.tmp/AppDir` and the next full run reported hardware failures
that were not happening. An aarch64 probe replaced a cached image and the suite
died on `Exec format error`. Adding the host's library directories to every GL
case made `glxgears` render on Alpine **with no shim at all**, through the X
server's own GLX -- which would have looked like a triumph and was the controls
quietly ceasing to control anything.

⭐ **The single most promising thing left, and it is not on any list.**
`plugin_boundaries.py` against the gtk4 AppDir reports **nine UNCLASSIFIED
loaders**, and one of them is `libepoxy.so.0` -- a GL entry-point loader, the
same DISPATCHER shape as libglvnd, sitting directly in the path of the
application this session used to find its last bug. It is almost certainly why
gtk4-demo's counts came out 1 GL and 46 GLES. Nobody has looked at it. 4.2 has
the row.

**What the next session should NOT redo:**

- `old-releases.ubuntu.com` for 14.04/16.04. They are on `archive.ubuntu.com`.
- Adding `mesa-egl` to `glfwd_host_dirs[]`. The list is derived now.
- Forcing `EGL_PLATFORM=surfaceless` and reading a Mesa 18 failure as a bug.
- Looking for a classic-Mesa host with a GPU on this machine. There is none.
