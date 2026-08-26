# security.md

What a pull request can and cannot do here, and the settings that decide it.

⚠ **Reporting a vulnerability is a different question**, and
[`../SECURITY.md`](../SECURITY.md) answers it. This page is about what CI
grants; that one is about a defect in the code.

⭐ **Everything else in this repository is checked by a file a reviewer can
read.** The settings below are not in the tree. They live on GitHub, they are
invisible from a clone, and they change without a commit, so they are written
down here and
[`../scripts/check-repo-settings.sh`](../scripts/check-repo-settings.sh)
reports which of them are on.

```bash
sh scripts/check-repo-settings.sh
```

⚠ It reads and changes nothing. Applying a setting stays a deliberate act by
somebody with admin, which is why the commands below are here rather than in
the script.

---

## What a pull request from outside can already not do

⭐ **Merge itself.** Merging needs write access, which is the collaborator
list, not something a pull request can grant itself.

⭐ **Reach a secret, or write anything.** A pull request from a fork runs with
a read-only token and no secrets. That is GitHub's behaviour and no setting in
this repository relaxes it. Its workflow code does run, which surprises people,
but it runs with nothing to spend.

⚠ **What it can do is waste a runner and read a public repository.** That is
the residual, and it is accepted.

---

## The settings, and what each one stops

| setting | without it |
|---|---|
| the default branch is protected | anyone with write access pushes straight to it, reviewing nothing |
| a pull request is required | the same |
| an approving review is required | one account can land its own change |
| a code-owner review is required | [`../.github/CODEOWNERS`](../.github/CODEOWNERS) changes nothing at all |
| status checks are required | a red build can be merged |
| force pushes blocked | history is rewritten under everyone |
| deletions blocked | the default branch can be removed |
| the default `GITHUB_TOKEN` is read-only | a workflow with no `permissions:` block of its own can write to the repository |
| a workflow cannot approve a pull request | a workflow satisfies the review requirement, and the review requirement stops meaning anything |

⛔ **Admins are deliberately NOT exempt from review by accident, they are
exempt on purpose.** `enforce_admins` is false so a trusted maintainer can
override when something has to land and the checks cannot run. An exemption
that exists is better than one improvised under pressure.

### Applying them

```bash
gh api -X PUT repos/pkgforge-dev/cross-libc-dlopen/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

Branch protection takes a JSON body, so it goes through a file. The required
contexts are the jobs that run on **every** pull request.

⚠ **Do not require a context that only runs sometimes.** `release.yml`'s jobs
run only on a pull request that touches the release path, so requiring one
would block every documentation change for ever, waiting on a check that never
reports.

---

## What is enforced in the tree instead

| | where |
|---|---|
| every workflow declares minimal `permissions:`, and only the tag-gated publish job escalates | [`../.github/workflows/`](../.github/workflows/) |
| every third-party action is pinned to a commit, not a tag, with the version in a trailing comment | the header of [`gates.yml`](../.github/workflows/gates.yml) |
| a release refuses to publish from a commit that never reached the default branch | the publish job in [`release.yml`](../.github/workflows/release.yml) |
| a release refuses to publish an artefact whose checksum disagrees with its manifest | [`../scripts/package-release.sh`](../scripts/package-release.sh) |
| no credential shape reaches a commit | [`../scripts/sweep-known-benign.sh`](../scripts/sweep-known-benign.sh), and TruffleHog beside it |

### The three scanners, and why more than one

They answer different questions, and a green run from any of them is not a
clearance.

- **TruffleHog**, with `--results=verified`, calls the provider to confirm a
  candidate credential is live. Near-zero false positives, and blind to a
  credential whose provider it cannot reach or one already revoked.
- **The template's pattern sweep**, narrowed at the call site, covers publish
  hygiene: emails, absolute home paths, and tracked credential files. None of
  those is a credential and no verifying scanner reports them.
- **GitGuardian** runs as an installed app on this repository, outside the
  workflows here.

⛔ **A real finding is REPORTED, never fixed silently.** Rotation comes first,
it is the operator's, and a history rewrite does not un-publish anything that
was readable.
