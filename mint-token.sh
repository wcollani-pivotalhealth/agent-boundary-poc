#!/usr/bin/env bash
# Mint a GitHub App installation access token from the App's private key.
# Usage: APP_ID=... INSTALLATION_ID=... PRIVATE_KEY_PATH=~/.config/agent-poc/key.pem ./mint-token.sh
set -euo pipefail

: "${APP_ID:?set APP_ID}"
: "${INSTALLATION_ID:?set INSTALLATION_ID}"
: "${PRIVATE_KEY_PATH:?set PRIVATE_KEY_PATH}"

if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
  echo "private key not found at $PRIVATE_KEY_PATH" >&2
  exit 1
fi

now=$(date +%s)
iat=$((now - 60))
exp=$((now + 540))

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

header='{"alg":"RS256","typ":"JWT"}'
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$APP_ID")

header_b64=$(printf '%s' "$header" | b64url)
payload_b64=$(printf '%s' "$payload" | b64url)
signing_input="${header_b64}.${payload_b64}"

signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | b64url)
jwt="${signing_input}.${signature}"

installation_token=$(curl -sS -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
  | tee /tmp/agent-poc-token-response.json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token",""))')

if [[ -z "$installation_token" ]]; then
  echo "failed to mint token, see /tmp/agent-poc-token-response.json" >&2
  exit 1
fi

echo "$installation_token"
