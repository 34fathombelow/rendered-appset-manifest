#!/usr/bin/env bash
#
# Render one ApplicationSet into a tree of one-Application-per-file manifests,
# laid out as <outdir>/<env>/<application-name>.yaml.
#
# Generation is server-side: `argocd appset generate` hands the AppSet to the
# ArgoCD API, which is what makes the git and cluster generators resolve for real.
# The env routing comes from the labels the AppSet templates stamp on every
# Application (see the "contract with scripts/render.sh" comment in appsets/).
#
# Environment-specific sync policy is applied HERE, to the generated output,
# rather than templated into the AppSets. The AppSets stay uniform and free of
# conditionals, and because the rendered manifests are committed, the effect of
# every rule below is visible in the diff on the rendered branch.
#
#   Usage: scripts/render.sh <appset-file> <outdir>
#   Env:   ARGOCD_SERVER, ARGOCD_AUTH_TOKEN   (optional; falls back to argocd login)
#
set -euo pipefail

APPSET="${1:?usage: render.sh <appset-file> <outdir>}"
# What the generated header should say this was rendered from. scripts/preview.sh
# renders a rewritten copy of the AppSet out of a temp directory, and without
# this the temp path would land in every header and make every file look changed.
APPSET_LABEL="${RENDER_APPSET_LABEL:-$APPSET}"
OUTDIR="${2:?usage: render.sh <appset-file> <outdir>}"

ENV_LABEL="gitops.34fathombelow.io/env"
TRACK_LABEL="gitops.34fathombelow.io/track"
VALID_ENVS="dev test prod"

# ---- render-time policy ----------------------------------------------------
# Keyed by "<track>/<env>". Anything not listed is left exactly as generated.
#
#   apps/prod    drop automated sync -- promoting a prod workload is a human act
#   addons/prod  keep automated sync, never prune -- a render that drops an addon
#                must not delete a running platform component
#
# Each rule is a yq expression applied to one Application document.
policy_for() {
  case "$1/$2" in
    apps/prod)   echo 'del(.spec.syncPolicy.automated)' ;;
    addons/prod) echo '.spec.syncPolicy.automated.prune = false' ;;
    *)           echo '' ;;
  esac
}

policy_note() {
  case "$1/$2" in
    apps/prod)   echo 'automated sync removed (prod workloads sync by hand)' ;;
    addons/prod) echo 'pruning disabled (prod addons are never auto-deleted)' ;;
    *)           echo '' ;;
  esac
}

# CI passes credentials explicitly. Locally, fall back to whatever `argocd login`
# already established, so a preview does not need a second set of credentials.
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

for bin in argocd yq; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

raw="$(mktemp -t appset-raw.XXXXXX)"
staging="$(mktemp -d -t appset-tree.XXXXXX)"
trap 'rm -f "$raw"; [[ -n "${staging:-}" ]] && rm -rf "$staging"; true' EXIT

echo "==> generating $APPSET"
argocd appset generate "$APPSET" "${auth[@]}" --grpc-web -o yaml > "$raw"

# `argocd appset generate -o yaml` emits a single YAML sequence of Applications.
count="$(yq 'length' "$raw")"
if [[ "$count" == "null" || "$count" -eq 0 ]]; then
  echo "error: $APPSET generated 0 Applications -- refusing to write an empty tree" >&2
  echo "       (a cluster generator returns nothing if no cluster carries the labels)" >&2
  exit 1
fi

# Everything is written into a staging directory and swapped into place only once
# the whole set renders cleanly, so a failure half way through can never leave a
# partial tree for CI to commit. The swap also replaces rather than merges, so an
# Application removed upstream disappears instead of lingering.
echo "==> writing $count Application(s) to $OUTDIR"
for i in $(seq 0 $((count - 1))); do
  name="$(yq -r ".[$i].metadata.name" "$raw")"
  env="$(yq -r ".[$i].metadata.labels.\"$ENV_LABEL\" // \"\"" "$raw")"
  track="$(yq -r ".[$i].metadata.labels.\"$TRACK_LABEL\" // \"\"" "$raw")"

  if [[ -z "$name" || "$name" == "null" ]]; then
    echo "error: Application at index $i has no metadata.name" >&2
    exit 1
  fi
  if [[ -z "$env" ]]; then
    echo "error: $name is missing the $ENV_LABEL label -- cannot route it" >&2
    exit 1
  fi
  if [[ ! " $VALID_ENVS " == *" $env "* ]]; then
    echo "error: $name has env '$env', not one of: $VALID_ENVS" >&2
    exit 1
  fi

  dest="$staging/$env/$name.yaml"
  if [[ -e "$dest" ]]; then
    echo "error: duplicate Application name '$name' in env '$env'" >&2
    echo "       two generator combinations rendered the same name; check the" >&2
    echo "       name template in $APPSET" >&2
    exit 1
  fi

  rule="$(policy_for "$track" "$env")"
  note="$(policy_note "$track" "$env")"

  mkdir -p "$staging/$env"
  {
    echo "# Generated from $APPSET_LABEL by scripts/render.sh -- do not edit."
    echo "# track: ${track:-unknown}  env: $env"
    [[ -n "$note" ]] && echo "# policy: $note"
    # ArgoCD needs these in argocd's namespace. Sorting keys last keeps the diff
    # stable across runs so a no-op render produces no commit.
    yq -P "(.[$i] | .metadata.namespace = \"argocd\")" "$raw" \
      | yq -P "${rule:-.}" \
      | yq -P 'sort_keys(..)'
  } > "$dest"
  if [[ -n "$note" ]]; then
    echo "    $env/$name.yaml  [$note]"
  else
    echo "    $env/$name.yaml"
  fi
done

rm -rf "$OUTDIR"
mkdir -p "$(dirname "$OUTDIR")"
mv "$staging" "$OUTDIR"
staging=""   # ownership handed over; keep the trap from deleting it

echo "==> done: $count Application(s)"
for d in "$OUTDIR"/*/; do
  [[ -d "$d" ]] || continue
  printf '    %-6s %s file(s)\n' "$(basename "$d")" "$(find "$d" -name '*.yaml' | wc -l | tr -d ' ')"
done
