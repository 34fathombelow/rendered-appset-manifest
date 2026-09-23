#!/usr/bin/env bash
#
# Render your local state and diff it against what each env branch holds: the
# open PR branch render/<env> if there is one, otherwise rendered-<env>. This is
# the diff your change would add to each env's PR.
#
# Generation is server-side, so ArgoCD reads clusters/, apps/ and addons/ from
# the REMOTE, never your working tree. Local edits to appsets/ are picked up as
# is (the AppSet file is sent from here). To include local edits to those three
# directories, this snapshots your working tree into a commit (without touching
# your branch or index), pushes it to a temporary branch preview/<you>-<pid>,
# renders from that, and deletes the branch on exit. It only does so when those
# directories actually differ from origin/main.
#
#   --stat  list changed files instead of the full diff
#
#   Usage: scripts/diff.sh [--stat] [env...]   (default envs: dev test prod)
#   Env:   same ArgoCD credentials as scripts/render.sh
#
set -euo pipefail

STAT=""
ENVS=()
for arg in "$@"; do
  case "$arg" in
    --stat) STAT=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option $arg (try --help)" >&2; exit 2 ;;
    *) ENVS+=("$arg") ;;
  esac
done
[[ ${#ENVS[@]} -gt 0 ]] || ENVS=(dev test prod)

cd "$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d -t appset-diff.XXXXXX)"
preview=""
cleanup() {
  [[ -n "$preview" ]] && git push -q origin --delete "$preview" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

git fetch -q --prune origin

# Anything that differs from remote main under the generator inputs: committed
# but unpushed, staged, unstaged, or untracked.
inputs=(clusters apps addons)
changed="$( { git diff --name-only origin/main -- "${inputs[@]}"
              git ls-files --others --exclude-standard -- "${inputs[@]}"; } | sort -u)"

if [[ -n "$changed" ]]; then
  # Snapshot the working tree into a commit via a throwaway index, so neither
  # your branch nor your staging area changes.
  export GIT_INDEX_FILE="$tmp/index"
  git read-tree HEAD
  git add -A
  tree="$(git write-tree)"
  unset GIT_INDEX_FILE
  commit="$(git commit-tree "$tree" -p HEAD -m "preview: local changes for scripts/diff.sh")"
  preview="preview/$(git config user.email | cut -d@ -f1 | tr -c 'a-zA-Z0-9-\n' '-')-$$"
  # Drop GitHub's "Create a pull request" hint; real errors still come through.
  git push -q origin "$commit:refs/heads/$preview" 2>&1 | { grep -v '^remote:' || true; } >&2
  echo "==> pushed local state to temporary branch $preview (deleted on exit)"
  export RENDER_REVISION="$commit"
fi

scripts/render.sh "$tmp/new" >/dev/null

for env in "${ENVS[@]}"; do
  if git rev-parse -q --verify "origin/render/$env" >/dev/null; then
    ref="origin/render/$env"
  elif git rev-parse -q --verify "origin/rendered-$env" >/dev/null; then
    ref="origin/rendered-$env"
  else
    ref=""
  fi

  mkdir -p "$tmp/cur/$env" "$tmp/new/$env"
  [[ -n "$ref" ]] && git archive "$ref" | tar -x -C "$tmp/cur/$env"

  echo "==> $env: local render vs ${ref:-(no branch yet)}"
  # --no-index diffs two plain directories; --relative keeps paths short.
  if (cd "$tmp" && git --no-pager diff --no-index --quiet "cur/$env" "new/$env"); then
    echo "    no changes"
  elif [[ -n "$STAT" ]]; then
    (cd "$tmp" && git --no-pager diff --no-index --stat "cur/$env" "new/$env") || true
  else
    (cd "$tmp" && git --no-pager diff --no-index "cur/$env" "new/$env") || true
  fi
done
