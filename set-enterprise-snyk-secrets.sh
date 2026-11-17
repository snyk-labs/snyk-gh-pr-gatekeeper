#!/usr/bin/env bash
# Set SNYK_TOKEN (secret) and SNYK_GROUP_ID (variable) on every org in a GitHub Enterprise.
#
# Usage:
#   SNYK_TOKEN=... ./set-enterprise-snyk-secrets.sh -e <enterprise-slug> -g <snyk-group-id> [-v private|all] [-n]
#
#   -e  GitHub enterprise slug (required)
#   -g  Snyk group ID, stored as the SNYK_GROUP_ID variable (required)
#   -v  Org visibility for the secret and variable: private (default; private + internal repos) or all (includes public)
#   -n  Dry run: list the orgs and what would be set, change nothing
#
# SNYK_TOKEN is read from the environment (never passed on the command line).
# Requires: gh, logged in with scopes read:enterprise and admin:org
#   gh auth refresh -h github.com -s read:enterprise -s admin:org
set -uo pipefail

ENTERPRISE=""; GROUP_ID=""; VISIBILITY="private"; DRY_RUN=0

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

while getopts "e:g:v:nh" opt; do
  case $opt in
    e) ENTERPRISE=$OPTARG ;;
    g) GROUP_ID=$OPTARG ;;
    v) VISIBILITY=$OPTARG ;;
    n) DRY_RUN=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done

[ -n "$ENTERPRISE" ] || { echo "error: -e <enterprise-slug> is required" >&2; usage 1; }
[ -n "$GROUP_ID" ]   || { echo "error: -g <snyk-group-id> is required" >&2; usage 1; }
case $VISIBILITY in private|all) ;; *) echo "error: -v must be 'private' or 'all'" >&2; exit 1 ;; esac
command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }
if [ "$DRY_RUN" -eq 0 ] && [ -z "${SNYK_TOKEN:-}" ]; then
  echo "error: SNYK_TOKEN is not set in the environment" >&2; exit 1
fi

# List all orgs in the enterprise (paginated).
ORGS=()
CURSOR=""
while :; do
  if [ -n "$CURSOR" ]; then AFTER=", after: \"$CURSOR\""; else AFTER=""; fi
  RESP=$(gh api graphql -f query="query { enterprise(slug: \"$ENTERPRISE\") { organizations(first: 100$AFTER) { nodes { login } pageInfo { hasNextPage endCursor } } } }") \
    || { echo "error: could not list orgs for enterprise '$ENTERPRISE' (check slug and read:enterprise scope)" >&2; exit 1; }
  while IFS= read -r login; do [ -n "$login" ] && ORGS+=("$login"); done \
    < <(echo "$RESP" | jq -r '.data.enterprise.organizations.nodes[].login')
  [ "$(echo "$RESP" | jq -r '.data.enterprise.organizations.pageInfo.hasNextPage')" = "true" ] || break
  CURSOR=$(echo "$RESP" | jq -r '.data.enterprise.organizations.pageInfo.endCursor')
done

[ "${#ORGS[@]}" -gt 0 ] || { echo "error: no orgs found in enterprise '$ENTERPRISE'" >&2; exit 1; }
echo "Enterprise '$ENTERPRISE': ${#ORGS[@]} org(s): ${ORGS[*]}"
echo "Visibility: $VISIBILITY"

FAILED=()
for org in "${ORGS[@]}"; do
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $org: would set secret SNYK_TOKEN and variable SNYK_GROUP_ID=$GROUP_ID"
    continue
  fi
  ok=1
  gh secret set SNYK_TOKEN --org "$org" --visibility "$VISIBILITY" --body "$SNYK_TOKEN" >/dev/null 2>&1 || ok=0
  gh variable set SNYK_GROUP_ID --org "$org" --visibility "$VISIBILITY" --body "$GROUP_ID" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then echo "ok      $org"; else echo "FAILED  $org"; FAILED+=("$org"); fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "Failed orgs: ${FAILED[*]}" >&2
  exit 1
fi
