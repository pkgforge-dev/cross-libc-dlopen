# REPORT

What was built, what was measured, and what is still broken.

Every claim is either backed by a command whose output is quoted, or labelled
**UNVERIFIED**. Nothing is estimated.

⭐ **This is the measured record, and every count and every suite total lives
here and nowhere else.** Everything outside it points back at a section number,
so a citation of the form `REPORT 9.14` names a subsection of section 9 and
resolves to the page below.

---

## The sections

| | section | what it records |
|---|---|---|
| 1 | [Summary](01-summary.md) | what the goals were and which of them were reached |
| 2 | [Environment reached](02-environment.md) | the machines, images and drivers every number below came from |
| 3 | [Defects found by measurement](03-defects-found-by-measurement.md) | six things that were wrong, each found by a case rather than by reading |
| 4 | [Design R: host-runtime selection](04-design-r-runtime-selection.md) | swapping the libc runtime at exec time, and why a mixed set cannot be allowed |
| 5 | [Design B: the generated shim](05-design-b-generated-shim.md) | the forward-compatibility shim, what it covers and what it cannot |
| 6 | [Goal 2, and the last blocker](06-goal-2-the-last-blocker.md) | a musl-built driver loading into a glibc process, and how the final blocker fell |
| 7 | [The closed-source driver and the ABI](07-closed-source-driver-and-abi.md) | a vendor stack on real silicon, and the struct hazards the boundary does and does not survive |
| 8 | [Test results](08-test-results.md) | every suite, every host, every named skip |
| 9 | [The second boundary](09-the-second-boundary.md) | a bundled dispatcher whose plugin the host lacks, which is the whole of the OpenGL work |
| 10 | [Measured versus assumed](10-measured-versus-assumed.md) | which claims rest on a run and which rest on a reading |
| 11 | [Known unfixed](11-known-unfixed.md) | what is broken on purpose, and what is out of scope |
| 12 | [Residual risk](12-residual-risk.md) | what could still be wrong, and what would show it |

⚠ **Section 9 is the largest by a wide margin** and stays whole. Its
subsections are cited by number from across the repository, and one topic split
across several pages makes `9.14` ambiguous about which page to open.

---

## How to read it

Start at [section 1](01-summary.md) for what was attempted.
[Section 8](08-test-results.md) is where a number is looked up.
[Section 10](10-measured-versus-assumed.md) is where a claim is checked against
what actually backs it.

⛔ **No number in this index.** The index names sections and says what each
covers, because a count repeated here would be a second home for a value that
is supposed to have one. [`../conventions/prose.md`](../conventions/prose.md)
has that rule and
[`../../.github/workflows/gates.yml`](../../.github/workflows/gates.yml) has
the check.
