#!/usr/bin/env bash
#
# Render both tracks at a given revision and diff the result against what is
# currently on the rendered branches. This is the preview CI cannot give you:
# rendering needs an ArgoCD token, so a pull request never shows the Application
# diff it will produce. Run this before opening one.
#
#   Usage: scripts/preview.sh [-r REVISION] [-t apps|addons|all]
#
#     -r  revision the generators should read from (default: current branch)
#     -t  which track to preview (default: all)
#
# Two things about how this works are easy to get wrong:
#
#   1. The generators in appsets/ are pinned to `revision: main`. Rendering a
#      feature branch without overriding that reads main's clusters/ and apps/,
#      so a newly added cluster shows no diff at all. This script rewrites the
#      generator revision (and only the generator revision -- the template's
#      targetRevision stays main, because that is what the Applications will
#      point at once merged).
#
#   2. `argocd appset generate` runs server-side, so ArgoCD fetches the revision
#      from the remote. Your uncommitted and unpushed work is invisible to it.
#      The script refuses to guess and tells you when the revision is not on the
#      remote, or when your local branch is ahead of it.
#
set -euo pipefail

REV=""
TRACK="all"
while getopts ":r:t:h" opt; do
  case "$opt" in
    r) REV="$OPTARG" ;;
    t) TRACK="$OPTARG" ;;
    h) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    \?) echo "unknown option -$OPTARG (try -h)" >&2; exit 2 ;;
    :)  echo "-$OPTARG needs a value" >&2; exit 2 ;;
  esac
done

case "$TRACK" in all|apps|addons) ;; *) echo "error: -t must be apps, addons or all" >&2; exit 2 ;; esac

cd "$(git rev-parse --show-toplevel)"
for bin in argocd yq git; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

[[ -n "$REV" ]] || REV="$(git rev-parse --abbrev-ref HEAD)"

# The server reads from the remote, so a revision it cannot fetch renders the
# wrong thing (or nothing) rather than failing loudly.
remote_sha="$(git ls-remote origin "refs/heads/$REV" 2>/dev/null | cut -f1)"
if [[ -z "$remote_sha" ]]; then
  echo "error: '$REV' does not exist on origin" >&2
  echo "       generation is server-side, so ArgoCD can only read pushed revisions." >&2
  echo "       push the branch first, or pass -r main to preview against main." >&2
  exit 1
fi
local_sha="$(git rev-parse "$REV" 2>/dev/null || true)"
if [[ -n "$local_sha" && "$local_sha" != "$remote_sha" ]]; then
  echo "warning: local $REV ($(git rev-parse --short "$REV")) differs from origin/$REV (${remote_sha:0:7})." >&2
  echo "         the preview reflects what is on the remote, not your working tree." >&2
  echo >&2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: working tree has uncommitted changes, which the preview cannot see." >&2
  echo >&2
fi

work="$(mktemp -d -t appset-preview.XXXXXX)"
trap 'rm -rf "$work"' EXIT

echo "==> previewing revision $REV (origin ${remote_sha:0:7})"
echo

added=0; removed=0; changed=0; rc=0

preview_track() {
  local track="$1" appset="appsets/$1.yaml" branch="rendered/$1"
  local patched="$work/$track-appset.yaml"

  # Repoint only the generators. .spec.template.spec.source.targetRevision is
  # deliberately left alone: the preview should show what merging produces.
  yq "(.spec.generators | .. | select(tag == \"!!map\" and has(\"revision\")) | .revision) = \"$REV\"" \
    "$appset" > "$patched"

  # Label the output with the real path, not the temp copy, so the rendered
  # headers match the branch and only genuine changes show up in the diff.
  RENDER_APPSET_LABEL="$appset" ./scripts/render.sh "$patched" "$work/$track/preview" >/dev/null

  # Materialise the current branch, if it exists yet.
  mkdir -p "$work/$track/current"
  if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    # Explicit forced refspec: a plain `git fetch origin <branch>` can leave the
    # remote-tracking ref stale after CI force-pushes, which would silently diff
    # against content the remote no longer has.
    git fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    git archive "origin/$branch" | tar -x -C "$work/$track/current"
    # CI writes this; render.sh does not produce it.
    rm -f "$work/$track/current/README.md"
  else
    echo "    ($branch does not exist yet, everything is new)"
  fi

  echo "--- $branch ---"
  local cur="$work/$track/current" new="$work/$track/preview"
  if diff -rqN "$cur" "$new" >/dev/null 2>&1; then
    echo "    no change"
    echo
    return
  fi
  rc=1

  # Per-Application summary before the line-level diff. Classified by which side
  # the file exists on rather than by diff's wording: under -N, diff calls a file
  # present on only one side "differ", which would report every new Application
  # as a modification.
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    cmp -s "$cur/$rel" "$new/$rel" && continue
    if [[ -f "$cur/$rel" && -f "$new/$rel" ]]; then
      echo "    ~ $rel"; changed=$((changed+1))
    elif [[ -f "$new/$rel" ]]; then
      echo "    + $rel"; added=$((added+1))
    else
      echo "    - $rel"; removed=$((removed+1))
    fi
  done < <(
    { [[ -d "$cur" ]] && ( cd "$cur" && find . -type f -name '*.yaml' | sed 's|^\./||' )
      [[ -d "$new" ]] && ( cd "$new" && find . -type f -name '*.yaml' | sed 's|^\./||' ); } | sort -u
  )

  echo
  # Run from inside the track directory so the diff shows current/<env>/<app>.yaml
  # rather than an absolute temp path, and disable rename detection: two unrelated
  # Applications are otherwise reported as one renamed file.
  (
    cd "$work/$track"
    git --no-pager diff --no-index --no-renames --stat current preview 2>/dev/null | sed 's/^/    /' || true
    echo
    git --no-pager diff --no-index --no-renames current preview 2>/dev/null || true
  )
  echo
}

[[ "$TRACK" == "all" || "$TRACK" == "apps"   ]] && preview_track apps
[[ "$TRACK" == "all" || "$TRACK" == "addons" ]] && preview_track addons

echo "==> $added added, $removed removed, $changed changed"
[[ $rc -eq 0 ]] && echo "    rendered branches are already up to date with $REV"
exit 0
