#!/usr/bin/env bash
#
# Render one ApplicationSet into a tree of one-Application-per-file manifests,
# laid out as <outdir>/<env>/<application-name>.yaml.
#
# Generation is server-side: `argocd appset generate` hands the AppSet to the
# ArgoCD API, which is what makes the git generators resolve for real. The env
# routing comes from the labels the AppSet templates stamp on every Application
# (see the "contract with scripts/render.sh" comment in appsets/).
#
# Environment-specific sync policy is applied HERE, to the generated output,
# rather than templated into the AppSets. The AppSets stay uniform and free of
# conditionals, and because the rendered manifests go through a PR, the effect
# of every rule below is visible in the diff.
#
#   Usage: scripts/render.sh <appset-file> <outdir>
#   Env:   ARGOCD_SERVER, ARGOCD_AUTH_TOKEN   (optional; falls back to argocd login)
#          RENDER_REVISION   commit the generators read instead of their `revision:`
#                            (CI sets it to the pushed SHA; see below)
#
set -euo pipefail

APPSET="${1:?usage: render.sh <appset-file> <outdir>}"
OUTDIR="${2:?usage: render.sh <appset-file> <outdir>}"

export ENV_LABEL="gitops.34fathombelow.io/env"
export TRACK_LABEL="gitops.34fathombelow.io/track"
export APPSET
VALID_ENVS="dev test prod"

# ---- render-time policy ----------------------------------------------------
# One yq expression over the whole generated list. Anything not matched is left
# exactly as generated.
#
#   apps/prod    drop automated sync -- promoting a prod workload is a human act
#   addons/prod  keep automated sync, never prune -- a render that drops an addon
#                must not delete a running platform component
#
# Every file also gets a provenance header, and is pinned to argocd's namespace.
# Sorting keys last keeps the diff stable so a no-op render changes nothing.
# shellcheck disable=SC2016  # $-free yq program; strenv() reads the exports above
TRANSFORM='
  .[] |= (
      .metadata.namespace = "argocd"
    | . head_comment = "Generated from " + strenv(APPSET) + " by scripts/render.sh -- do not edit.\n"
        + "track: " + .metadata.labels[strenv(TRACK_LABEL)] + "  env: " + .metadata.labels[strenv(ENV_LABEL)]
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

raw="$(mktemp -t appset-raw.XXXXXX)"
staging="$(mktemp -d -t appset-tree.XXXXXX)"
trap 'rm -f "$raw"; [[ -n "${staging:-}" ]] && rm -rf "$staging"; true' EXIT

# The generators say `revision: main`, and ArgoCD resolves that through its own
# cache, so a render started seconds after a push can read the PREVIOUS commit --
# e.g. an AppSet that references a key the old cluster configs lack. Pinning the
# generators to an exact SHA makes the render read the commit that triggered it.
# Only generator revisions change; the template's targetRevision stays as written.
src="$APPSET"
if [[ -n "${RENDER_REVISION:-}" ]]; then
  src="$(mktemp -t appset-src.XXXXXX)"
  trap 'rm -f "$raw" "$src"; [[ -n "${staging:-}" ]] && rm -rf "$staging"; true' EXIT
  yq '(.spec.generators | .. | select(tag == "!!map" and has("revision")) | .revision) = strenv(RENDER_REVISION)' \
    "$APPSET" > "$src"
fi

echo "==> generating $APPSET${RENDER_REVISION:+ at ${RENDER_REVISION::12}}"
argocd appset generate "$src" "${auth[@]}" --grpc-web -o yaml > "$raw"

# `argocd appset generate -o yaml` emits a single YAML sequence of Applications.
count="$(yq 'length' "$raw")"
if [[ "$count" == "null" || "$count" -eq 0 ]]; then
  echo "error: $APPSET generated 0 Applications -- refusing to write an empty tree" >&2
  exit 1
fi

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
while read -r dup; do
  echo "error: duplicate Application '$dup' -- two generator combinations rendered" >&2
  echo "       the same name; check the name template in $APPSET" >&2
  fail=1
done < <(yq -r '.[] | .metadata.labels[strenv(ENV_LABEL)] + "/" + .metadata.name' "$raw" | sort | uniq -d)
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
