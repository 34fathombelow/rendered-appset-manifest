#!/usr/bin/env bash
#
# Rewrite the repository URL everywhere it is hard-coded. Run this once after
# forking, before the first push.
#
#   Usage: scripts/set-repo.sh https://github.com/your-org/your-repo.git
#
set -euo pipefail

ORIGINAL="https://github.com/34fathombelow/rendered-appset-manifest.git"
NEW="${1:?usage: set-repo.sh <new-repo-url>}"

if [[ "$NEW" == "$ORIGINAL" ]]; then
  echo "New URL matches the current one. Nothing to do."
  exit 0
fi

cd "$(git rev-parse --show-toplevel)"

# Plain while-read rather than mapfile: macOS still ships bash 3.2.
found=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sed -i.bak "s|${ORIGINAL}|${NEW}|g" "$f"
  rm -f "${f}.bak"
  echo "  updated $f"
  found=$((found + 1))
done < <(grep -rl --fixed-strings "$ORIGINAL" . --exclude-dir=.git || true)

if [[ $found -eq 0 ]]; then
  echo "No occurrences of $ORIGINAL found -- already rewritten?"
  exit 0
fi

cat <<'NEXT'

Done. Remaining steps:

  1. Point clusters/*/config.yaml at your real clusters
       cluster.name must match the cluster's name as registered in ArgoCD.

  2. Let kustomize inflate Helm charts, which the addon overlays rely on
       kubectl -n argocd patch cm argocd-cm --type merge \
         -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}'

  3. Label the cluster secrets so the addon track's cluster generator sees them
       kubectl -n argocd label secret <cluster-secret> addons=true env=dev

  4. Add repository secrets
       ARGOCD_SERVER      ArgoCD server hostname, no scheme
       ARGOCD_AUTH_TOKEN  token for a proj:addons:appset-generate account

  5. Commit and push main, then let the workflow create the rendered branches
       gh workflow run ci.yaml -f track=all

  6. Bootstrap the cluster once
       kubectl apply -f bootstrap/root.yaml
NEXT
