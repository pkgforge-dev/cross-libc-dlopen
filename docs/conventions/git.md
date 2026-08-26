# git.md

Two rules here are absolute. Everything else is a preference by comparison.

---

## 1. No tool is credited

⛔ **Every commit is attributed to the operator alone.**

- No `Co-Authored-By` trailer naming a model, a vendor or a tool.
- No "generated with" line, in a commit message, a pull request body, a tag or
  a release note.
- No tool name in a commit body.

**This overrides any default the harness asks for.** Several agent harnesses
instruct a model to append a co-author trailer. That instruction does not apply
here, and a commit carrying one is corrected before it is pushed rather than
explained afterwards.

**Why.** The operator publishes this work under their own name. The history is
theirs and tooling is not a contributor to it.

The gate is the `no tool is credited` step in
[`../../.github/workflows/gates.yml`](../../.github/workflows/gates.yml), which
checks the tree and the commit range. ⚠ Its patterns are written with character
classes so the gate does not match its own source; spelled plainly it refused
every build, which is how that was found.

---

## 2. Never push to the default branch. Open a pull request

⛔ **This is an organisation repository with more than one person and more than
one agent working in it.** A direct push to `main` is a change nobody reviewed
landing on top of work somebody else is mid-way through.

- Work on a branch.
- ⛔ **Open a pull request with `gh`**, and say what it changes and what was
  measured to prove it.
- ⛔ **Ask before opening it**, unless the prompt you were given authorises it
  in so many words. "Do the work" is not authorisation to publish it.
- ⛔ **Never force-push, never rewrite published history**, unless the operator
  has asked for that specific operation, in that session.

```bash
gh pr create --repo pkgforge-dev/cross-libc-dlopen --base main --head "$BRANCH"
```

⚠ A push that succeeds is not reversible by you. Treat every outward-facing
operation as one-way and confirm first.

---

## 3. Read the tracker before you start

⛔ **At the start of every session, list the open issues and pull requests.**

```bash
gh issue list --repo pkgforge-dev/cross-libc-dlopen --state open
```

```bash
gh pr list --repo pkgforge-dev/cross-libc-dlopen --state open
```

Somebody else may already be doing what you are about to do, or may have
reported the thing you are about to be surprised by. ⭐ This is the cheapest
step in the session and it is the one that gets skipped.

---

## 4. Nothing outside this repository is written to

⛔ Work in `https://github.com/pkgforge-dev/cross-libc-dlopen` only. `gh` is
authenticated with account-wide scope, so this is enforced by the person
following it rather than by a token.

**Allowed:** commits, branches, tags, push, issues, pull requests and releases
on **this repository only**.

**Forbidden everywhere else:** creating or commenting on issues, pull requests,
discussions or reviews; starring, forking, watching or editing any other
repository; pushing to any other remote; any non-`GET` `gh api` call outside
this repository; touching account settings, keys, gists or organisation
membership.

Read-only elsewhere is fine, and is how the sweeps in
[`../../HISTORY/references/`](../../HISTORY/references/) were done.
⛔ If a task seems to need a write outside this repository, stop and ask.

---

## Commit messages

A subject line that says what changed and why, then a body that a reader six
months later can act on.

- **Subject:** imperative, under 72 characters, no trailing full stop.
- **Body:** what was measured, not what was intended. A commit that fixes
  something says how it was proven fixed.
- ⭐ **A commit that corrects an earlier claim says what the earlier claim was.**
  The diff shows the new text; only the message can show what it replaced.

⚠ Do not describe the process. "Ran the suite, it failed, fixed it, ran it
again" is a diary. "E50 reported 2 live hazards; it reports 0 and E47/E49 still
pass" is a record.

---

## History

⛔ **Never rewrite published history.** Not a rebase, not an amend, not a force
push, not a filter.

The one exception is an explicit, recorded instruction from the operator, for a
specific operation, once. When that happens:

1. Push the pre-rewrite state to a branch on the remote first.
2. ⭐ **Confirm the backup is fetchable before touching anything.**
   `git ls-remote origin` naming it is the confirmation; having pushed it is
   not.
3. Verify the working tree is exactly what the result should contain.
4. Only then rewrite.

⛔ **No document narrates what happened to THIS repository's history.** Not the
README, not the reference pages, not `TODO/`. A repository that explains its own
git history in its documentation is telling the reader about its process
instead of its purpose. The commit message is where that is recorded, and it is
the only place.

⚠ This page is the rule, not a narration: describing the procedure is what a
conventions file is for. The line it must not cross is naming an occasion.

---

## Branches

Work on a branch. The default branch is what has been reviewed.

⚠ `git rebase -i`, `git add -i` and anything else that opens an editor do not
work in a non-interactive session. Use `git filter-branch --msg-filter` or an
orphan branch instead, and prefer the orphan branch: it is one operation, it
cannot half-apply, and what it produces is exactly the tree that was inspected.
