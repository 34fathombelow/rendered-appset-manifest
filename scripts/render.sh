#!/usr/bin/env bash
#
# Render every ApplicationSet into ONE tree of one-Application-per-file
# manifests, laid out as <outdir>/<env>/<application-name>.yaml (scripts/publish.sh
# turns each <env>/ into that env's rendered-<env> branch). Rendering them
# together is what lets one PR per env carry all of them, and what lets the
# duplicate-name check below catch a clash between two AppSets.
#
# Generation is server-side: `argocd appset generate` hands each AppSet to the
# ArgoCD API, which is what makes the git generators resolve for real. Routing
# comes from the env label every AppSet template must stamp on its Applications
# (see the "contract with scripts/render.sh" comment in appsets/).
#
# Environment-specific sync policy is applied HERE, to the generated output,
# rather than templated into the AppSets. The AppSets stay uniform and free of
# conditionals, and because the rendered manifests go through a PR, the effect
# of every rule below is visible in the diff.
#
#   Usage: scripts/render.sh <outdir> [appset-file...]   (default: appsets/*.yaml)
#   Env:   ARGOCD_SERVER, ARGOCD_AUTH_TOKEN   (optional; falls back to argocd login)
#          RENDER_REVISION   commit the generators read instead of their `revision:`
#                            (CI sets it to the pushed SHA; see below)
#
set -euo pipefail

OUTDIR="${1:?usage: render.sh <outdir> [appset-file...]}"
shift
if [[ $# -gt 0 ]]; then
  APPSETS=("$@")
else
  APPSETS=(appsets/*.yaml)
fi

export ENV_LABEL="gitops.34fathombelow.io/env"
export TRACK_LABEL="gitops.34fathombelow.io/track"
VALID_ENVS="dev test prod"

# ---- render-time policy ----------------------------------------------------
# One yq expression over the whole generated list, keyed on the track and env
# labels. Anything not matched is left exactly as generated.
#
#   apps/prod    drop automated sync -- promoting a prod workload is a human act
#   addons/prod  keep automated sync, never prune resources inside the addon
#
# Every file also gets a provenance header naming its AppSet (carried in from the
# generate loop as a temporary `.renderSource` key), and is pinned to argocd's
# namespace. Sorting keys last keeps the diff stable so a no-op render changes
# nothing.
# shellcheck disable=SC2016  # $-free yq program; strenv() reads the exports above
TRANSFORM='
  .[] |= (
      .metadata.namespace = "argocd"
    | . head_comment = "Generated from " + .renderSource + " by scripts/render.sh -- do not edit.\n"
        + "track: " + (.metadata.labels[strenv(TRACK_LABEL)] // "none")
        + "  env: " + (.metadata.labels[strenv(ENV_LABEL)] // "none")
    | del(.renderSource)
  )
  | (.[] | select(.metadata.labels[strenv(TRACK_LABEL)] == "apps" and .metadata.labels[strenv(ENV_LABEL)] == "prod")) |= (
      del(.spec.syncPolicy.automated)
    | . head_comment = head_comment + "\npolicy: automated sync removed (prod workloads sync by hand)"
  )
  | (.[] | select(.metadata.labels[strenv(TRACK_LABEL)] == "addons" and .metadata.labels[strenv(ENV_LABEL)] == "prod")) |= (
      .spec.syncPolicy.automated.prune = false
    | . head_comment = head_comment + "\npolicy: pruning disabled (prod addons are never auto-deleted)"
  )
  | .[] | sort_keys(..)
'

for bin in argocd yq; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

# CI passes credentials explicitly. Locally, fall back to whatever `argocd login`
# already established.
TOKEN="${ARGOCD_AUTH_TOKEN:-${ARGOCD_TOKEN:-}}"
auth=()
if [[ -n "${ARGOCD_SERVER:-}" ]]; then
  auth+=(--server "$ARGOCD_SERVER")
  [[ -n "$TOKEN" ]] && auth+=(--auth-token "$TOKEN")
elif ! argocd account get-user-info --grpc-web >/dev/null 2>&1; then
  echo "error: no ARGOCD_SERVER set and no usable 'argocd login' session" >&2
  echo "       either export ARGOCD_SERVER and ARGOCD_AUTH_TOKEN, or run argocd login" >&2
  exit 1
fi

work="$(mktemp -d -t appset-work.XXXXXX)"
staging="$(mktemp -d -t appset-tree.XXXXXX)"
trap 'rm -rf "$work"; [[ -n "${staging:-}" ]] && rm -rf "$staging"; true' EXIT
raw="$work/all.yaml"

# The generators say `revision: main`, and ArgoCD resolves that through its own
# cache, so a render started seconds after a push can read the PREVIOUS commit --
# e.g. an AppSet that references a key the old cluster configs lack. Pinning the
# generators to an exact SHA makes the render read the commit that triggered it.
# Only generator revisions change; the template's targetRevision stays as written.
for appset in "${APPSETS[@]}"; do
  src="$appset"
  if [[ -n "${RENDER_REVISION:-}" ]]; then
    src="$work/src.yaml"
    yq '(.spec.generators | .. | select(tag == "!!map" and has("revision")) | .revision) = strenv(RENDER_REVISION)' \
      "$appset" > "$src"
  fi

  echo "==> generating $appset${RENDER_REVISION:+ at ${RENDER_REVISION::12}}"
  argocd appset generate "$src" "${auth[@]}" --grpc-web -o yaml > "$work/one.yaml"

  # `argocd appset generate -o yaml` emits a single YAML sequence of Applications.
  n="$(yq 'length' "$work/one.yaml")"
  if [[ "$n" == "null" || "$n" -eq 0 ]]; then
    echo "error: $appset generated 0 Applications -- refusing to publish that" >&2
    echo "       (it would delete every Application it owns)" >&2
    exit 1
  fi
  echo "    $n Application(s)"

  # Record which AppSet each Application came from while we still know it; the
  # transform turns this into the file header and removes it.
  export APPSET="$appset"
  yq '.[] |= .renderSource = strenv(APPSET)' "$work/one.yaml" > "$work/gen-$(basename "$appset")"
done
# shellcheck disable=SC2016  # yq variable, not a shell one
yq ea '. as $list ireduce ([]; . + $list)' "$work"/gen-*.yaml > "$raw"
count="$(yq 'length' "$raw")"

# ---- checks, all before anything is written --------------------------------
fail=0
# Counted rather than listed: yq prints a bare string literal once even when
# the select before it matched nothing.
if [[ "$(yq '[.[] | select(.metadata.name == null)] | length' "$raw")" -ne 0 ]]; then
  echo "error: an Application has no metadata.name" >&2; fail=1
fi
while read -r name env; do
  if [[ "$env" == "null" ]]; then
    echo "error: $name is missing the $ENV_LABEL label -- cannot route it" >&2; fail=1
  elif [[ " $VALID_ENVS " != *" $env "* ]]; then
    echo "error: $name has env '$env', not one of: $VALID_ENVS" >&2; fail=1
  fi
done < <(yq -r '.[] | select(.metadata.name) | .metadata.name + " " + (.metadata.labels[strenv(ENV_LABEL)] // "null")' "$raw")
# Names must be unique across ALL AppSets: every Application lives in argocd's
# namespace, whatever env directory it is written to.
while read -r dup; do
  echo "error: duplicate Application '$dup' -- two generator combinations, possibly" >&2
  echo "       in different AppSets, rendered the same name; check the name templates" >&2
  fail=1
done < <(yq -r '.[] | .metadata.name' "$raw" | sort | uniq -d)
[[ $fail -eq 0 ]] || exit 1

# Everything is written into a staging directory and swapped into place only once
# the whole set renders cleanly, so a failure half way through can never leave a
# partial tree. The swap also replaces rather than merges, so an Application
# removed upstream disappears instead of lingering.
echo "==> writing $count Application(s) to $OUTDIR"
( cd "$staging" && yq -P -s '.metadata.labels[strenv(ENV_LABEL)] + "/" + .metadata.name + ".yaml"' "$TRANSFORM" "$raw" )

rm -rf "$OUTDIR"
mkdir -p "$(dirname "$OUTDIR")"
mv "$staging" "$OUTDIR"
staging=""   # ownership handed over; keep the trap from deleting it

echo "==> done: $count Application(s)"
for d in "$OUTDIR"/*/; do
  [[ -d "$d" ]] || continue
  printf '    %-6s %s file(s)\n' "$(basename "$d")" "$(find "$d" -name '*.yaml' | wc -l | tr -d ' ')"
done
