#!/usr/bin/env bash
#
# Publish a rendered tree as one pull request per environment against
# rendered/<track>, instead of pushing to it directly. Nothing reaches a cluster
# until the PR for that environment is merged, and each PR shows exactly the
# Application changes that environment will get.
#
# Each env PR touches only its own <env>/ directory, so they never conflict with
# one another and can be merged in any order -- dev today, prod next week. Every
# run rebuilds the PR branches from the current tip of rendered/<track>, so an
# open PR always holds the latest render of main; an env whose render matches
# the branch has its PR closed.
#
#   Usage: scripts/publish.sh <track> <rendered-dir>
#   Env:   GH_TOKEN      token gh uses to open/update/close PRs
#          GITHUB_SHA    main commit being published (default: HEAD)
#          DRY_RUN=1     print each env's diff; push nothing, touch no PRs
#
set -euo pipefail

TRACK="${1:?usage: publish.sh <track> <rendered-dir>}"
RENDERED="${2:?usage: publish.sh <track> <rendered-dir>}"
BASE="rendered/$TRACK"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
DRY_RUN="${DRY_RUN:-}"
VALID_ENVS="dev test prod"

[[ -d "$RENDERED" ]] || { echo "error: $RENDERED is not a directory" >&2; exit 1; }
RENDERED="$(cd "$RENDERED" && pwd)"
for bin in git gh; do
  [[ -n "$DRY_RUN" && "$bin" == gh ]] && continue
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

readme() {
  cat <<MD
# $BASE -- generated branch

Every file here is produced by \`scripts/render.sh\` from \`appsets/$TRACK.yaml\`
on \`main\`. Do not edit it by hand: CI opens one pull request per environment
(\`render/$TRACK/<env>\`) against this branch, and merging that PR is what
deploys the change to that environment.

Layout: \`<env>/<application-name>.yaml\`, one ArgoCD Application per file.
MD
}

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

fetch_base() {
  git fetch -q origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
}

# The README lives on the base branch only. Writing it from the env PRs would
# make every one of them touch the same file and conflict after the first merge.
# It is excluded by the app-of-apps, so committing it directly deploys nothing.
if git ls-remote --exit-code --heads origin "$BASE" >/dev/null 2>&1; then
  fetch_base
  wt="$tmp/wt-base"
  git worktree add -q --detach "$wt" "origin/$BASE"
else
  echo "==> $BASE does not exist; creating it with only a README"
  wt="$tmp/wt-base"
  git worktree add -q --detach "$wt"
  git -C "$wt" checkout -q --orphan "$BASE"
  git -C "$wt" rm -rqf . || true
fi
readme > "$wt/README.md"
git -C "$wt" add README.md
if ! git -C "$wt" diff --cached --quiet; then
  git -C "$wt" commit -qm "docs($TRACK): branch README"
  if [[ -n "$DRY_RUN" ]]; then
    echo "==> [dry-run] would update README on $BASE"
  else
    git -C "$wt" push -q origin "HEAD:refs/heads/$BASE"
    fetch_base
  fi
fi
base_ref="$(git -C "$wt" rev-parse HEAD)"
git worktree remove --force "$wt"

for env in $VALID_ENVS; do
  head="render/$TRACK/$env"
  echo "==> $TRACK/$env"

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

  git -C "$wt" commit -qm "render($TRACK/$env): from main@${SHA::8}"
  git -C "$wt" push -qf origin "HEAD:refs/heads/$head"

  title="render($TRACK/$env): main@${SHA::8}"
  body="$(cat <<MD
Rendered from \`appsets/$TRACK.yaml\` at main@$SHA.

Merging deploys these Application changes to **$env**. This PR is rebuilt on
every render of main, so it always holds the latest one.

| status | file |
|--------|------|
$(echo "$changes" | awk -F'\t' '{ s = ($1 == "A") ? "added" : ($1 == "D") ? "deleted" : "modified"; printf "| %s | `%s` |\n", s, $2 }')
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
