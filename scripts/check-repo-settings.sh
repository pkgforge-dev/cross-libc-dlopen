#!/bin/sh
# Are the repository settings that no file can enforce actually set?
#
# ⭐ EVERY OTHER CHECK IN THIS REPOSITORY LIVES IN THE TREE, so a reviewer can
# read it and CI can run it. These cannot: branch protection, the default
# workflow token, and whether a fork's first pull request runs workflows are
# settings on GitHub, invisible from a clone and changeable without a commit.
# A setting nobody can see is a setting that drifts.
#
#   sh scripts/check-repo-settings.sh
#
# ⚠ It READS. It changes nothing. docs/security.md has the command to set each
# one, so applying them stays a deliberate act by somebody with admin.
#
# ⚠ It needs a token with admin read on the repository. Without one the
# Actions and protection queries return 403 or 404 and are reported as
# UNKNOWN rather than as pass or fail: "the check could not look" and "the
# setting is off" are different answers and must not print the same.
#
# Exit 0 everything required is set, 1 something is not, 2 could not run.
set -u

command -v gh >/dev/null 2>&1 || { echo "check-repo-settings: no gh on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "check-repo-settings: no jq on PATH" >&2; exit 2; }

SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) ||
	{ echo "check-repo-settings: cannot resolve the repository" >&2; exit 2; }
BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)

fail=0
ok()      { printf '  ok      %s\n' "$*"; }
bad()     { printf '  NOT SET %s\n' "$*"; fail=1; }
unknown() { printf '  UNKNOWN %s\n' "$*"; }

printf '\n== %s, default branch %s ==\n\n' "$SLUG" "$BRANCH"

# ------------------------------------------------- 1. who can write at all --
printf -- '-- write access --\n'
if writers=$(gh api "repos/$SLUG/collaborators" --paginate \
             --jq '.[] | select(.role_name == "admin" or .role_name == "write") | .login' 2>/dev/null); then
	n=$(printf '%s\n' "$writers" | grep -c . || true)
	printf '  %s account(s) can push: %s\n' "$n" "$(printf '%s' "$writers" | tr '\n' ' ')"
	printf '  ⚠ Every one of them can merge. .github/CODEOWNERS should name the same set.\n'
else
	unknown "the collaborator list could not be read"
fi
echo

# ------------------------------------------- 2. the default branch is safe --
printf -- '-- branch protection on %s --\n' "$BRANCH"
prot=$(gh api "repos/$SLUG/branches/$BRANCH/protection" 2>/dev/null) || prot=""
if [ -z "$prot" ]; then
	bad "$BRANCH is NOT protected. Anyone with write access can push straight to it,
          and no pull request, review or green check is required."
else
	pr=$(printf '%s' "$prot" | jq -r '.required_pull_request_reviews // empty')
	[ -n "$pr" ] && ok "a pull request is required" ||
		bad "a pull request is not required"

	rc=$(printf '%s' "$prot" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')
	[ "$rc" -ge 1 ] && ok "$rc approving review(s) required" ||
		bad "no approving review is required"

	co=$(printf '%s' "$prot" | jq -r '.required_pull_request_reviews.require_code_owner_reviews // false')
	[ "$co" = true ] && ok "a code-owner review is required, so CODEOWNERS has teeth" ||
		bad "code-owner review is not required, so .github/CODEOWNERS changes nothing"

	sc=$(printf '%s' "$prot" | jq -r '.required_status_checks.contexts // [] | length')
	[ "$sc" -gt 0 ] && ok "$sc status check(s) required to be green before merging" ||
		bad "no status check is required, so a red build can be merged"

	fp=$(printf '%s' "$prot" | jq -r '.allow_force_pushes.enabled // false')
	[ "$fp" = false ] && ok "force pushes are blocked" || bad "force pushes are ALLOWED"

	dl=$(printf '%s' "$prot" | jq -r '.allow_deletions.enabled // false')
	[ "$dl" = false ] && ok "branch deletion is blocked" || bad "branch deletion is ALLOWED"

	ea=$(printf '%s' "$prot" | jq -r '.enforce_admins.enabled // false')
	if [ "$ea" = true ]; then
		printf '  note    admins are NOT exempt. Nobody can override, including the operator.\n'
	else
		printf '  note    admins may override, which is the deliberate escape hatch.\n'
	fi
fi
echo

# ------------------------------------------------ 3. what a workflow may do --
printf -- '-- the token every workflow gets --\n'
if wf=$(gh api "repos/$SLUG/actions/permissions/workflow" 2>/dev/null); then
	dp=$(printf '%s' "$wf" | jq -r '.default_workflow_permissions')
	[ "$dp" = read ] && ok "the default GITHUB_TOKEN is read-only" ||
		bad "the default GITHUB_TOKEN is '$dp'. A workflow with no permissions:
          block of its own can write to this repository."

	ap=$(printf '%s' "$wf" | jq -r '.can_approve_pull_request_reviews')
	[ "$ap" = false ] && ok "a workflow cannot approve a pull request" ||
		bad "a workflow CAN approve a pull request, which defeats a review requirement"
else
	unknown "the Actions token policy could not be read (admin scope needed)"
fi
echo

printf -- '-- what runs on a pull request from a fork --\n'
if ap=$(gh api "repos/$SLUG/actions/permissions" 2>/dev/null); then
	sp=$(printf '%s' "$ap" | jq -r '.sha_pinning_required // false')
	[ "$sp" = true ] && ok "actions must be pinned to a SHA" ||
		printf '  note    SHA pinning is not enforced by the platform. This repository
          pins every action by convention; gates.yml says why.\n'
else
	unknown "the Actions policy could not be read (admin scope needed)"
fi
printf '  ⚠ A pull request from a FORK always gets a read-only token and no
    secrets, whatever the setting above says. That is GitHub, not this
    repository, and it is why a fork cannot write here even though its
    workflow code runs.\n'
echo

if [ "$fail" = 0 ]; then
	printf '  every required setting is on\n'
	exit 0
fi
printf '  ⛔ Something above is not set. docs/security.md has the command for each.\n'
exit 1
