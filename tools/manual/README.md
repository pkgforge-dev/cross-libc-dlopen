# tools/manual

⭐ **A tool nothing runs on a schedule, kept because its output is cited.**

A test no runner runs is a test that has already stopped working and nobody has
noticed. What is here is not a test. It is an analysis tool a person invokes
when the thing it reads has changed, and putting it here says so rather than
leaving it beside the generators CI runs on every push.

⛔ **Nothing was deleted, and "nothing runs it" is not on its own a reason to.**
It is cited from a document, and deleting the file without the citation leaves
that document pointing at nothing.

| tool | what it is for | who cites it |
|---|---|---|
| [`trap_users.py`](trap_users.py) | intersects an object's imports with the version-trap set, so you can ask which traps a specific driver would actually hit | [`../../docs/report/README.md`](../../docs/report/README.md) |

```bash
python3 tools/manual/trap_users.py /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/libm.so.6
```

---

## ⚠ What this directory nearly broke

`tools/libc_inventory.py` was moved here too, on the recorded premise that
nothing ran it. ⛔ **That premise was wrong, and it is worth reading why.**
`tools/gen_forward_shim.py` imports it by MODULE name, `make shim` runs that
generator, and CI runs `make shim` and diffs the result on every push. The
premise had been measured by grepping the tree for the FILENAME, and an import
never spells one.

It is back in [`../`](../), where it belongs.

`trap_users.py` broke a second way in the same move. Both its `sys.path.insert`
lines inserted its own directory, which was harmless while every tool sat
together and became an `ImportError` for `elfsym` and `version_traps` the
moment one did not. It now inserts the parent as well.

⭐ **Both classes are checked now.** `sh scripts/check-drift.sh` fails when a
document cites a path that does not exist, and when a tool imports a module
that is not reachable from its own directory or the one above it.
[`../../docs/todo/infrastructure.md`](../../docs/todo/infrastructure.md) T-14 has the
full record, including the corrected premise.

The tools that stay in [`../`](../) are reached by `make shim`, `make gl-syms`,
`make gles-syms` or `make traps`, and CI runs the first of those on every push.
