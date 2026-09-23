#!/usr/bin/env bash
#
# Generate one ApplicationSet into a single multi-document YAML file that
# `kubectl apply -f` accepts. Handy for inspecting or hand-applying the output;
# CI uses scripts/render.sh, which also applies env policy and splits per file.
#
# `argocd appset generate -o yaml` emits one YAML *sequence* of Applications,
# which kubectl rejects ("invalid object to validate"). yq's split_doc turns
# each element into its own `---` document. This deliberately avoids sed: GNU
# and BSD (macOS) sed disagree on `\n` in replacements, so it runs the same on
# Linux and macOS.
#
#   Usage: scripts/generate.sh <appset-file> <out-file>
#   Env:   ARGOCD_SERVER, ARGOCD_AUTH_TOKEN   (optional; falls back to argocd login)
#
set -euo pipefail

APPSET="${1:?usage: generate.sh <appset-file> <out-file>}"
OUT="${2:?usage: generate.sh <appset-file> <out-file>}"

for bin in argocd yq; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found on PATH" >&2; exit 1; }
done

TOKEN="${ARGOCD_AUTH_TOKEN:-${ARGOCD_TOKEN:-}}"
auth=()
if [[ -n "${ARGOCD_SERVER:-}" ]]; then
  auth+=(--server "$ARGOCD_SERVER")
  [[ -n "$TOKEN" ]] && auth+=(--auth-token "$TOKEN")
elif ! argocd account get-user-info --grpc-web >/dev/null 2>&1; then
  echo "error: no ARGOCD_SERVER set and no usable 'argocd login' session" >&2
  exit 1
fi

raw="$(mktemp -t appset-raw.XXXXXX)"
trap 'rm -f "$raw"' EXIT

argocd appset generate "$APPSET" "${auth[@]}" --grpc-web -o yaml > "$raw"

count="$(yq 'length' "$raw")"
if [[ "$count" == "null" || "$count" -eq 0 ]]; then
  echo "error: $APPSET generated 0 Applications" >&2
  exit 1
fi

# kubectl apply silently lets a later document overwrite an earlier one with
# the same name, so catch name collisions here instead.
dupes="$(yq -r '.[].metadata.name' "$raw" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "error: duplicate Application name(s) generated from $APPSET:" >&2
  while read -r d; do echo "    $d" >&2; done <<< "$dupes"
  exit 1
fi

{
  echo "# Generated from $APPSET by scripts/generate.sh -- do not edit."
  yq '.[] | split_doc' "$raw"
} > "$OUT"

echo "==> $count Application(s) written to $OUT"
