#!/usr/bin/env bash
# seed-zitadel.sh — auto-seed the Zitadel resources the DTL app needs, headless (no console).
#
# Mechanism (confirmed empirically on v2.71.10 — see plans/handoff-prep-spike.md):
#   Zitadel FirstInstance seeds a machine (service-account) user + PAT to a file on first
#   start-from-init. THIS script uses that PAT against the Management REST API to create:
#     1. Project        "DTL App"
#     2. Native PKCE App "dtl-electron"  (auth method NONE — public client, no secret)
#     3. Human user      testuser@dtl.local  (email verified, password preset, no mail)
#
# It ASSERTS (fails loud, non-zero, no partial output) — per plan Decisions 13 & 14:
#   - the created app's registered redirect === the redirect passed in (config.js source of truth)
#   - the created app has NO client secret (proves public PKCE native app)
#   - the app and the user share the same resourceOwner (same Zitadel org)
#
# Usage:  seed-zitadel.sh <pat-file> <issuer-base-url> <redirect-uri>
# Output: the fresh client_id on stdout (nothing else on stdout — captured by setup.sh).
set -euo pipefail

PAT_FILE="${1:?Usage: seed-zitadel.sh <pat-file> <issuer-base-url> <redirect-uri>}"
BASE="${2:?issuer base url required, e.g. http://127.0.0.1:8090}"
REDIRECT_URI="${3:?redirect uri required (from config.js)}"

TEST_USER="testuser@dtl.local"
TEST_PASS="Test1234!"

log()  { echo "[seed] $*" >&2; }   # all diagnostics to stderr; stdout is reserved for client_id
die()  { echo "[seed] ERROR: $*" >&2; exit 1; }

[[ -f "$PAT_FILE" ]] || die "PAT file not found: $PAT_FILE (did FirstInstance run with PATPATH set?)"
PAT="$(tr -d '[:space:]' < "$PAT_FILE")"
[[ -n "$PAT" ]] || die "PAT file is empty: $PAT_FILE"

# api <METHOD> <path> [json-body]  -> echoes response body; dies on non-2xx.
api() {
  local method="$1" path="$2" body="${3:-}"
  local resp code
  resp="$(curl -s -w $'\n%{http_code}' -X "$method" "$BASE$path" \
            -H "Authorization: Bearer $PAT" \
            -H "Content-Type: application/json" \
            ${body:+-d "$body"})"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  if [[ "$code" != 2* ]]; then
    die "$method $path -> HTTP $code: $body"
  fi
  printf '%s' "$body"
}

# jget <json> <python-expression-on-d>  -> extracts a value, dies if missing/empty.
jget() {
  printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); v=($2); print('' if v is None else v)"
}

log "authenticating PAT (whoami)..."
WHO="$(api GET /auth/v1/users/me)"
SA_USER="$(jget "$WHO" "d.get('user',{}).get('userName')")"
[[ -n "$SA_USER" ]] || die "PAT auth failed — /auth/v1/users/me returned no user"
log "PAT ok, service account: $SA_USER"

log "creating project 'DTL App'..."
PROJ="$(api POST /management/v1/projects '{"name":"DTL App"}')"
PID="$(jget "$PROJ" "d['id']")"
[[ -n "$PID" ]] || die "project create returned no id"
log "project id: $PID"

log "creating native PKCE app 'dtl-electron' with redirect $REDIRECT_URI ..."
APP_BODY="$(python3 - "$REDIRECT_URI" <<'PY'
import json,sys
redirect = sys.argv[1]
print(json.dumps({
  "name": "dtl-electron",
  "redirectUris": [redirect],
  "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
  "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
  "appType": "OIDC_APP_TYPE_NATIVE",
  "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
  "accessTokenType": "OIDC_TOKEN_TYPE_BEARER"
}))
PY
)"
APP="$(api POST "/management/v1/projects/$PID/apps/oidc" "$APP_BODY")"
CLIENT_ID="$(jget "$APP" "d.get('clientId')")"
APP_ID="$(jget "$APP" "d.get('appId')")"
CLIENT_SECRET="$(jget "$APP" "d.get('clientSecret','')")"
[[ -n "$CLIENT_ID" ]] || die "app create returned no clientId"
[[ -z "$CLIENT_SECRET" ]] || die "app has a client secret — not a public PKCE native app (Decision 13)"
log "client_id: $CLIENT_ID (no secret — public PKCE native app, ok)"

# Decision 13: re-fetch the app and assert the registered redirect matches EXACTLY.
log "verifying registered redirect matches config.js ($REDIRECT_URI)..."
APP_GET="$(api GET "/management/v1/projects/$PID/apps/$APP_ID")"
REG_REDIRECT="$(jget "$APP_GET" "(d.get('app',{}).get('oidcConfig',{}).get('redirectUris') or [''])[0]")"
[[ "$REG_REDIRECT" == "$REDIRECT_URI" ]] || \
  die "redirect mismatch (Decision 13): registered='$REG_REDIRECT' expected='$REDIRECT_URI'"
APP_OWNER="$(jget "$APP_GET" "d.get('app',{}).get('details',{}).get('resourceOwner') or d.get('app',{}).get('resourceOwner','')")"
log "redirect verified; app resourceOwner: $APP_OWNER"

log "importing human user $TEST_USER (email verified, password preset)..."
USER_BODY="$(python3 - "$TEST_USER" "$TEST_PASS" <<'PY'
import json,sys
email, pw = sys.argv[1], sys.argv[2]
print(json.dumps({
  "userName": email,
  "profile": {"firstName": "Test", "lastName": "User"},
  "email": {"email": email, "isEmailVerified": True},
  "password": pw,
  "passwordChangeRequired": False
}))
PY
)"
USER="$(api POST /management/v1/users/human/_import "$USER_BODY")"
USER_ID="$(jget "$USER" "d['userId']")"
[[ -n "$USER_ID" ]] || die "user import returned no userId"

# Confirm the user is active + email verified, and grab its resourceOwner for the same-org assert.
USER_GET="$(api GET "/management/v1/users/$USER_ID")"
USER_STATE="$(jget "$USER_GET" "d['user']['state']")"
USER_VERIFIED="$(jget "$USER_GET" "d['user']['human']['email'].get('isEmailVerified')")"
USER_OWNER="$(jget "$USER_GET" "d['user'].get('details',{}).get('resourceOwner') or d['user'].get('resourceOwner','')")"
[[ "$USER_STATE" == "USER_STATE_ACTIVE" ]] || die "user not active: $USER_STATE"
[[ "$USER_VERIFIED" == "True" ]] || die "user email not verified"
log "user active + email verified; user resourceOwner: $USER_OWNER"

# Decision 14: app and user must live in the same org.
[[ -n "$APP_OWNER" && "$APP_OWNER" == "$USER_OWNER" ]] || \
  die "same-org mismatch (Decision 14): app owner='$APP_OWNER' user owner='$USER_OWNER'"
log "same-org verified: $APP_OWNER"

log "seeding complete — emitting client_id on stdout"
printf '%s\n' "$CLIENT_ID"
