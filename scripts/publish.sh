#!/usr/bin/env bash
#
# Publish a rendered tree as one pull request per environment against the
# `rendered` branch, instead of pushing to it directly. Nothing reaches a cluster
# until the PR for that environment is merged, and each PR shows exactly the
# Application changes -- from every AppSet -- that environment will get.
#
# Each env PR touches only its own <env>/ directory, so they never conflict with
# one another and can be merged in any order -- dev today, prod next week. Every
# run rebuilds the PR branches from the current tip of `rendered`, so an open PR
# always holds the latest render of main; an env whose render matches the branch
# has its PR closed.
#
#   Usage: scripts/publish.sh <rendered-dir>
#   Env:   GH_TOKEN      token gh uses to open/update/close PRs
#          GITHUB_SHA    main commit being published (default: HEAD)
#          DRY_RUN=1     print each env's diff; push nothing, touch no PRs
#
set -euo pipefail

RENDERED="${1:?usage: publish.sh <rendered-dir>}"
BASE="rendered"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
DRY_RUN="${DRY_RUN:-}"
VALID_ENVS="dev test prod"

[[ -d "$RENDERED" ]] || { echo "error: $RENDERED is not a directory" >&2; exit 1; }
RENDERED="$(cd "$RENDERED" && pwd)"
for bin in git gh; do
  [[ -n "$DRY_RUN" && "$bin" == gh ]] && continue
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

tmp="$(mktemp -d -t publish.XXXXXX)"
cleanup() {
  local w
  for w in "$tmp"/wt-*; do
    [[ -d "$w" ]] && git worktree remove --force "$w"
  done
  rm -rf "$tmp"
  git worktree prune
}
trap cleanup EXIT

# --prune drops stale remote-tracking refs, which matters here: git cannot hold
# refs/remotes/origin/rendered while an old refs/remotes/origin/rendered/<x> lingers.
if git ls-remote --exit-code --heads origin "$BASE" >/dev/null 2>&1; then
  git fetch -q --prune origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
  base_ref="$(git rev-parse "origin/$BASE")"
else
  # First run: start the branch as an empty root commit, so the first env PRs
  # add every Application and show the whole initial state for review.
  echo "==> $BASE does not exist; creating it empty"
  empty_tree="$(git hash-object -t tree /dev/null)"
  base_ref="$(git commit-tree "$empty_tree" -m "rendered: empty root")"
  if [[ -n "$DRY_RUN" ]]; then
    echo "    [dry-run] would push it"
  else
    git push -q origin "$base_ref:refs/heads/$BASE"
  fi
fi

for env in $VALID_ENVS; do
  head="render/$env"
  echo "==> $env"

  wt="$tmp/wt-$env"
  git worktree add -q --detach "$wt" "$base_ref"
  # Replace this env's directory wholesale, so an Application that stopped
  # generating is deleted in the PR rather than lingering.
  rm -rf "${wt:?}/$env"
  [[ -d "$RENDERED/$env" ]] && cp -R "$RENDERED/$env" "$wt/$env"
  git -C "$wt" add -A

  pr=""
  if [[ -z "$DRY_RUN" ]]; then
    pr="$(gh pr list --base "$BASE" --head "$head" --state open --json number -q '.[0].number')"
  fi

  if git -C "$wt" diff --cached --quiet; then
    echo "    no changes"
    if [[ -n "$pr" ]]; then
      gh pr close "$pr" --delete-branch \
        --comment "Superseded: $BASE already matches the render of main@${SHA::8}."
      echo "    closed #$pr"
    fi
    git worktree remove --force "$wt"
    continue
  fi

  changes="$(git -C "$wt" diff --cached --name-status)"
  if [[ -n "$DRY_RUN" ]]; then
    echo "$changes" | while read -r line; do echo "    $line"; done
    git -C "$wt" --no-pager diff --cached --stat
    git worktree remove --force "$wt"
    continue
  fi

  git -C "$wt" commit -qm "render($env): from main@${SHA::8}"
  git -C "$wt" push -qf origin "HEAD:refs/heads/$head"

  title="render($env): main@${SHA::8}"
  body="$(cat <<MD
Rendered from \`appsets/*.yaml\` at main@$SHA.

Merging deploys these Application changes to **$env**. A **deleted** row tears
down that Application's workloads. This PR is rebuilt on every render of main,
so it always holds the latest one.

| status | file |
|--------|------|
$(echo "$changes" | awk -F'\t' '{ s = ($1 == "A") ? "added" : ($1 == "D") ? "**deleted**" : "modified"; printf "| %s | `%s` |\n", s, $2 }')
MD
)"
  if [[ -n "$pr" ]]; then
    gh pr edit "$pr" --title "$title" --body "$body" >/dev/null
    echo "    updated #$pr"
  else
    gh pr create --base "$BASE" --head "$head" --title "$title" --body "$body"
  fi
  git worktree remove --force "$wt"
done
