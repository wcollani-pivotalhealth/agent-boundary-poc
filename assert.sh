#!/usr/bin/env bash
# Runs the assertion matrix from ONBOARDING.md against the live repo, twice: once as the
# operator (gh's own token) and once as the agent-propose GitHub App (installation token).
# Records observed HTTP status per row -- no expectations baked in, see ONBOARDING.md.
#
# Usage: APP_TOKEN=$(./mint-token.sh) OTHER_REPO=owner/some-other-repo ./assert.sh
set -uo pipefail

: "${APP_TOKEN:?set APP_TOKEN, e.g. APP_TOKEN=\$(./mint-token.sh)}"
OWNER="wcollani-pivotalhealth"
REPO="agent-boundary-poc"
API="https://api.github.com/repos/${OWNER}/${REPO}"
OTHER_REPO="${OTHER_REPO:-${OWNER}/agent-boundary-poc-other}"
OP_TOKEN=$(gh auth token)
STAMP=$(date +%s)

RESULTS_FILE=$(mktemp)

req() {
  # req METHOD PATH TOKEN [DATA]
  local method="$1" path="$2" token="$3" data="${4:-}"
  if [[ -n "$data" ]]; then
    curl -sS -o /tmp/agent-poc-body.json -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" \
      -d "$data" "$path"
  else
    curl -sS -o /tmp/agent-poc-body.json -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" \
      "$path"
  fi
}

record() { echo "| $1 | $2 | $3 | $4 |" >> "$RESULTS_FILE"; }

echo "| Operation | Actor | HTTP status | Notes |" > "$RESULTS_FILE"
echo "|---|---|---|---|" >> "$RESULTS_FILE"

main_sha=$(gh api "repos/${OWNER}/${REPO}/git/ref/heads/main" --jq .object.sha)

run_actor_flow() {
  local actor="$1" token="$2"
  local branch="${actor}-test-${STAMP}"

  # read/clone
  code=$(req GET "${API}" "$token")
  record "read repo" "$actor" "$code" ""

  # push a branch (create ref + one commit via contents API)
  code=$(req POST "${API}/git/refs" "$token" "$(printf '{"ref":"refs/heads/%s","sha":"%s"}' "$branch" "$main_sha")")
  record "push a branch" "$actor" "$code" "branch=$branch"

  content_b64=$(printf 'hello from %s at %s' "$actor" "$STAMP" | base64)
  code=$(req PUT "${API}/contents/${actor}-file-${STAMP}.txt" "$token" \
    "$(printf '{"message":"test commit by %s","content":"%s","branch":"%s"}' "$actor" "$content_b64" "$branch")")
  record "commit to branch" "$actor" "$code" ""

  # open a PR
  code=$(req POST "${API}/pulls" "$token" \
    "$(printf '{"title":"test PR by %s","head":"%s","base":"main"}' "$actor" "$branch")")
  pr_number=$(python3 -c 'import json; print(json.load(open("/tmp/agent-poc-body.json")).get("number",""))')
  record "open a PR" "$actor" "$code" "pr=#${pr_number}"

  # push directly to main
  code=$(req PATCH "${API}/git/refs/heads/main" "$token" \
    "$(printf '{"sha":"%s","force":false}' "$main_sha")")
  record "push directly to main" "$actor" "$code" ""

  # merge own PR, no approvals yet
  if [[ -n "$pr_number" ]]; then
    code=$(req PUT "${API}/pulls/${pr_number}/merge" "$token" '{}')
    record "merge own PR (no approvals)" "$actor" "$code" "pr=#${pr_number}"
  fi

  echo "$pr_number"
}

echo "== operator flow ==" >&2
op_pr=$(run_actor_flow "operator" "$OP_TOKEN" | tail -1)
echo "== app flow ==" >&2
app_pr=$(run_actor_flow "app" "$APP_TOKEN" | tail -1)

# Unknown 1: does the App's approval satisfy a required human approval, and vice versa?
if [[ -n "$op_pr" ]]; then
  code=$(req POST "${API}/pulls/${op_pr}/reviews" "$APP_TOKEN" '{"event":"APPROVE"}')
  record "App approves operator's PR" "app-as-reviewer" "$code" "pr=#${op_pr}"
  code=$(req PUT "${API}/pulls/${op_pr}/merge" "$OP_TOKEN" '{}')
  record "operator merges own PR after App-only approval" "operator" "$code" "pr=#${op_pr} -- ANSWERS UNKNOWN 1"
fi

if [[ -n "$app_pr" ]]; then
  code=$(req POST "${API}/pulls/${app_pr}/reviews" "$APP_TOKEN" '{"event":"APPROVE"}')
  record "App approves its own PR" "app" "$code" "pr=#${app_pr} -- expect 422, self-approval"
  code=$(req POST "${API}/pulls/${app_pr}/reviews" "$OP_TOKEN" '{"event":"APPROVE"}')
  record "operator approves App's PR" "operator-as-reviewer" "$code" "pr=#${app_pr}"
  code=$(req PUT "${API}/pulls/${app_pr}/merge" "$APP_TOKEN" '{}')
  record "App merges its own PR after human approval" "app" "$code" "pr=#${app_pr}"
fi

# edit the ruleset (needs `administration`, App does not have it)
ruleset_id=$(gh api "repos/${OWNER}/${REPO}/rulesets" --jq '.[0].id')
code=$(req PATCH "${API}/rulesets/${ruleset_id}" "$APP_TOKEN" '{"enforcement":"disabled"}')
record "edit the ruleset" "app" "$code" "ruleset=$ruleset_id"

# delete the repo (needs `administration`)
code=$(req DELETE "${API}" "$APP_TOKEN")
record "delete the repo" "app" "$code" ""

# touch a different repo the App is not installed on
code=$(req GET "https://api.github.com/repos/${OTHER_REPO}" "$APP_TOKEN")
record "touch a different repo (not installed)" "app" "$code" "repo=${OTHER_REPO}"

echo
cat "$RESULTS_FILE"
