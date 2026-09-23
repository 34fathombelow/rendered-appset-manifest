#!/usr/bin/env bash
#
# Offline checks on the source of truth. Needs no ArgoCD server and no secrets,
# so it can gate pull requests -- which matters, because the render itself cannot
# run on a fork PR without exposing credentials.
#
# Catches the failure modes this layout is actually prone to:
#   - a cluster config missing a field the AppSet template dereferences
#   - an overlay directory named after an environment that does not exist
#   - an addon.yaml whose addon.name disagrees with its directory
#   - two generator combinations that would render the same Application name
#
set -euo pipefail

VALID_ENVS="dev test prod"
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }
ok()  { echo "  ok  $*"; }

command -v yq >/dev/null || { echo "error: yq not found on PATH" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"

echo "==> YAML parses"
# git ls-files rather than find: it respects .gitignore, so the charts/ trees a
# local `kustomize build --enable-helm` leaves behind are skipped. Those hold
# Helm templates, which are deliberately not valid YAML.
while IFS= read -r f; do
  yq -e 'true' "$f" >/dev/null 2>&1 || err "$f is not valid YAML"
done < <(git ls-files 'appsets/*.yaml' 'clusters/*.yaml' 'apps/*.yaml' 'addons/*.yaml' 'argocd/*.yaml' 'bootstrap/*.yaml')
[[ $fail -eq 0 ]] && ok "all tracked YAML parses"

echo "==> cluster configs"
cluster_envs=""
cluster_names=""
for f in clusters/*/config.yaml; do
  dir="$(basename "$(dirname "$f")")"
  for key in cluster.name cluster.env cluster.region; do
    v="$(yq -r ".$key // \"\"" "$f")"
    [[ -n "$v" && "$v" != "null" ]] || err "$f is missing .$key"
  done
  name="$(yq -r '.cluster.name // ""' "$f")"
  env="$(yq -r '.cluster.env // ""' "$f")"

  [[ "$name" == "$dir" ]] || err "$f: cluster.name '$name' != directory '$dir'"
  [[ " $VALID_ENVS " == *" $env "* ]] || err "$f: cluster.env '$env' not in: $VALID_ENVS"

  case " $cluster_names " in *" $name "*) err "duplicate cluster.name '$name'";; esac
  cluster_names="$cluster_names $name"
  case " $cluster_envs " in *" $env "*) ;; *) cluster_envs="$cluster_envs $env";; esac

  # The addons AppSet dereferences cluster.addons, so with missingkey=error a
  # missing key fails the whole render, not just this cluster. An unknown name or
  # a missing overlay would instead be skipped silently by the files generator.
  if [[ "$(yq -r '.cluster.addons | tag' "$f")" != "!!seq" ]]; then
    err "$f: cluster.addons must be a list (use [] for no addons)"
    continue
  fi
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    if [[ ! -d "addons/$a" ]]; then
      err "$f: enables addon '$a', but addons/$a does not exist"
    elif [[ ! -f "addons/$a/overlays/$env/addon.yaml" ]]; then
      err "$f: enables addon '$a', but it has no overlays/$env/addon.yaml"
    fi
  done < <(yq -r '.cluster.addons[]' "$f")
done
ok "clusters:$cluster_names"
ok "envs in use:$cluster_envs"

echo "==> app overlays"
for d in apps/*/overlays/*; do
  [[ -d "$d" ]] || continue
  env="$(basename "$d")"
  [[ " $VALID_ENVS " == *" $env "* ]] || err "$d: '$env' is not a valid environment"
  [[ -f "$d/kustomization.yaml" ]] || err "$d has no kustomization.yaml"
done
for d in apps/*/; do
  app="$(basename "$d")"
  [[ -f "$d/base/kustomization.yaml" ]] || err "apps/$app/base has no kustomization.yaml"
  # An app with no overlays at all is dead weight the matrix will never pair.
  n=$(find "$d/overlays" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" -gt 0 ]] || err "apps/$app has no overlays -- it will never be generated"
done
ok "app overlays reference known environments"

echo "==> addon overlays"
for d in addons/*/overlays/*; do
  [[ -d "$d" ]] || continue
  env="$(basename "$d")"
  addon="$(basename "$(dirname "$(dirname "$d")")")"
  [[ " $VALID_ENVS " == *" $env "* ]] || err "$d: '$env' is not a valid environment"

  f="$d/addon.yaml"
  if [[ ! -f "$f" ]]; then
    # Without addon.yaml the git files generator simply skips it -- silently.
    err "$d has no addon.yaml, so the files generator will never match it"
    continue
  fi
  for key in addon.name addon.namespace; do
    v="$(yq -r ".$key // \"\"" "$f")"
    [[ -n "$v" && "$v" != "null" ]] || err "$f is missing .$key"
  done
  n="$(yq -r '.addon.name // ""' "$f")"
  [[ "$n" == "$addon" ]] || err "$f: addon.name '$n' != directory '$addon'"
  [[ -f "$d/kustomization.yaml" ]] || err "$d has no kustomization.yaml"
done
ok "addon overlays are well-formed"

echo "==> predicted Application names are unique"
# Mirrors the name templates in appsets/. Cheap way to catch a collision before
# the render fails in CI.
names=""
for cfg in clusters/*/config.yaml; do
  cname="$(yq -r '.cluster.name' "$cfg")"
  cenv="$(yq -r '.cluster.env' "$cfg")"
  for d in apps/*/overlays/"$cenv"; do
    [[ -d "$d" ]] || continue
    app="$(basename "$(dirname "$(dirname "$d")")")"
    n="$app-$cname"
    case " $names " in *" $n "*) err "predicted duplicate Application '$n'";; esac
    names="$names $n"
  done
  while IFS= read -r addon; do
    [[ -n "$addon" ]] || continue
    n="$addon-$cname"
    case " $names " in *" $n "*) err "predicted duplicate Application '$n'";; esac
    names="$names $n"
  done < <(yq -r '.cluster.addons // [] | .[]' "$cfg")
done
count=$(echo "$names" | wc -w | tr -d ' ')
ok "$count Application name(s) predicted, all unique"

echo "==> appsets reference this repo consistently"
repo="$(yq -r '.spec.template.spec.source.repoURL' appsets/apps.yaml)"
# One file at a time: yq interleaves "---" separators when handed several.
for f in appsets/*.yaml argocd/app-of-apps/*.yaml argocd/projects/*.yaml bootstrap/root.yaml; do
  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "null" ]] || continue
    [[ "$r" == "$repo" ]] || err "$f: repoURL '$r' != '$repo'"
  done < <(yq -r '[.. | select(tag == "!!map" and has("repoURL")) | .repoURL] | .[]' "$f")
  # AppProject spells it sourceRepos instead.
  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "null" ]] || continue
    [[ "$r" == "$repo" ]] || err "$f: sourceRepos entry '$r' != '$repo'"
  done < <(yq -r '.spec.sourceRepos // [] | .[]' "$f")
done
ok "all repoURLs agree: $repo"

echo "==> one app-of-apps per env, each adopting its own branch"
for env in $VALID_ENVS; do
  f="argocd/app-of-apps/$env.yaml"
  [[ -f "$f" ]] || { err "missing $f"; continue; }
  # Pointing at another env's branch would deploy that env's Applications here.
  [[ "$(yq -r '.spec.source.targetRevision' "$f")" == "rendered-$env" ]] \
    || err "$f: targetRevision is not rendered-$env"
  # A finalizer here would cascade one delete into the whole environment.
  [[ "$(yq -r '.metadata.finalizers // [] | length' "$f")" == "0" ]] \
    || err "$f: must not carry a finalizer"
done
for f in argocd/app-of-apps/*.yaml; do
  env="$(basename "$f" .yaml)"
  [[ " $VALID_ENVS " == *" $env "* ]] || err "$f: '$env' is not a valid environment"
done
ok "app-of-apps: one per env, each on rendered-<env>"

echo "==> every AppSet stamps the env label render.sh routes on"
for f in appsets/*.yaml; do
  [[ "$(yq -r '.spec.template.metadata.labels["gitops.34fathombelow.io/env"] // ""' "$f")" != "" ]] \
    || err "$f: template has no gitops.34fathombelow.io/env label"
done
ok "appsets label their Applications with an env"

echo
if [[ $fail -ne 0 ]]; then
  echo "validation FAILED" >&2
  exit 1
fi
echo "validation passed"
