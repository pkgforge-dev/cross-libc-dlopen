# tools/manual

⭐ **Tools nothing runs on a schedule, kept because their output is cited.**

A test no runner runs is a test that has already stopped working and nobody has
noticed. These two are not tests. They are regeneration and analysis tools that
a person invokes when the thing they read has changed, and moving them here
says so, rather than leaving them beside the generators CI does run.

⛔ **Neither was deleted, and "nothing runs it" is not on its own a reason to.**
Both are cited from documents, and deleting the file without the citation
leaves a document pointing at nothing.

| tool | what it is for | who cites it |
|---|---|---|
| [`libc_inventory.py`](libc_inventory.py) | produced `inventories/*.json`, the measured symbol inventories `tools/gen_forward_shim.py` consumes. Run it again when the bundled glibc changes, not before | [`../../docs/ground-truth.md`](../../docs/ground-truth.md) |
| [`trap_users.py`](trap_users.py) | intersects an object's imports with the version-trap set, so you can ask which traps a specific driver would actually hit | [`../../docs/REPORT.md`](../../docs/REPORT.md) |

⚠ **Being here is not permission to rot.** `sh scripts/check-drift.sh` fails if
a document cites a path that does not exist, so a rename breaks a check rather
than a reader. What it cannot check is whether either still produces correct
output, and neither has been re-run since it was moved.

The two tools `tools/` keeps are different: `gen_forward_shim.py` and
`gen_gl_fwd.py` are run by `make shim`, `make gl-syms` and `make gles-syms`,
and CI re-runs the first and diffs the result on every push.
