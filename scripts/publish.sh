#!/usr/bin/env bash
#
# Publish a rendered tree as one pull request per environment, each against that
# environment's own branch (rendered-dev, rendered-test, rendered-prod), instead
# of pushing to them directly. Nothing reaches a cluster until the PR for that
# environment is merged, and each PR shows exactly the Application changes --
# from every AppSet -- that environment will get.
#
# One branch per env means each env has its own history, and its own branch
# protection (e.g. more required approvals on rendered-prod). Each branch holds
# only its env's Applications, one per file at the branch root.
#
# Every run rebuilds the PR branches from the current tip of their env branch,
# so an open PR always holds the latest render of main; an env whose render
# matches its branch has its PR closed.
#
#   Usage: scripts/publish.sh <rendered-dir>     (as written by scripts/render.sh)
#   Env:   GH_TOKEN      token gh uses to open/update/close PRs
#          GITHUB_SHA    main commit being published (default: HEAD)
#          DRY_RUN=1     print each env's diff; push nothing, touch no PRs
#
set -euo pipefail

RENDERED="${1:?usage: publish.sh <rendered-dir>}"
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

for env in $VALID_ENVS; do
  base="rendered-$env"
  head="render/$env"
  echo "==> $env ($base)"

  if git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1; then
    git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base"
    base_ref="$(git rev-parse "origin/$base")"
  else
    # First run: start the branch as an empty root commit, so the first PR adds
    # every Application and shows the env's whole initial state for review.
    echo "    $base does not exist; creating it empty"
    empty_tree="$(git hash-object -t tree /dev/null)"
    base_ref="$(git commit-tree "$empty_tree" -m "$base: empty root")"
    if [[ -n "$DRY_RUN" ]]; then
      echo "    [dry-run] would push it"
    else
      git push -q origin "$base_ref:refs/heads/$base"
    fi
  fi

  wt="$tmp/wt-$env"
  git worktree add -q --detach "$wt" "$base_ref"
  # Replace the whole tree, so an Application that stopped generating is
  # deleted in the PR rather than lingering.
  find "$wt" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  [[ -d "$RENDERED/$env" ]] && cp -R "$RENDERED/$env/." "$wt/"
  git -C "$wt" add -A

  pr=""
  if [[ -z "$DRY_RUN" ]]; then
    pr="$(gh pr list --base "$base" --head "$head" --state open --json number -q '.[0].number')"
  fi

  if git -C "$wt" diff --cached --quiet; then
    echo "    no changes"
    if [[ -n "$pr" ]]; then
      gh pr close "$pr" --delete-branch \
        --comment "Superseded: $base already matches the render of main@${SHA::8}."
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
    gh pr create --base "$base" --head "$head" --title "$title" --body "$body"
  fi
  git worktree remove --force "$wt"
done
