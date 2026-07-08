#!/usr/bin/env bash
# setup.sh — ONE command to stand up the entire DTL App test lab from scratch, headless.
#
# Brings up: OpenSSL cert chain -> NSS provisioning -> nginx (:8443/:8444/:8445) ->
#            Postgres -> Zitadel (start-from-init, auto-seeded machine SA + PAT) ->
#            seed Project + Native PKCE App + testuser@dtl.local via Management API ->
#            write lab/.runtime-env (fresh client_id + absolute DTL_KILL_CA_PATH).
#
# ZERO Web Console interaction. Real Zitadel (Authorization Code + PKCE) — only the SETUP is
# automated, never the auth. See plans/handoff-prep-spike.md for the full design + empirical proof.
#
# ⚠️ ONE-WAY DOOR (plan Decision 12): the clean-slate step DESTROYS any existing manually-seeded
#    Zitadel on :8090 and re-seeds from scratch. Intended (reproducible-from-scratch) but
#    irreversible — only run this once you're ready to switch to the auto-seeded instance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Pinned image (v4+ breaks the single-container console — see lab/zitadel/README.md).
ZITADEL_IMAGE="ghcr.io/zitadel/zitadel:v2.71.10"
POSTGRES_IMAGE="postgres:16-alpine"
NGINX_IMAGE="nginx:alpine"
MASTERKEY="MasterkeyNeedsToHave32Characters"   # exactly 32 chars — throwaway local value
SEED_DIR="$REPO_ROOT/lab/zitadel/.seed"
PAT_FILE="$SEED_DIR/pat.txt"
RUNTIME_ENV="$REPO_ROOT/lab/.runtime-env"
CA_ABS="$REPO_ROOT/lab/certs/ca.pem"

log()  { echo "[setup] $*"; }
die()  { echo "[setup] ERROR: $*" >&2; exit 1; }

# ── Step 0: preflight — prerequisites are checked, never installed (no sudo assumed) ─────────────
log "Step 0/11 — preflight prerequisite check..."
MISSING=()
for bin in podman node npm openssl certutil pk12util curl python3 dbus-run-session gnome-keyring-daemon; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
python3 -c "import dbus" >/dev/null 2>&1 || MISSING+=("python3-dbus (python3-dbus apt package)")
if (( ${#MISSING[@]} )); then
  echo "[setup] MISSING PREREQUISITES: ${MISSING[*]}" >&2
  echo "[setup] Install hints:" >&2
  echo "  podman / dbus-run-session          : rootless podman, dbus-x11" >&2
  echo "  node / npm                         : Node 20+ (nvm)" >&2
  echo "  certutil / pk12util                : sudo apt install libnss3-tools" >&2
  echo "  gnome-keyring-daemon / python3-dbus : sudo apt install gnome-keyring python3-dbus" >&2
  echo "  openssl / curl / python3            : base system packages" >&2
  die "prerequisites missing — nothing was changed. Install the above and re-run."
fi
log "all prerequisites present."

# ── config.js is the SINGLE SOURCE OF TRUTH for issuer + redirect (plan Decision 13) ─────────────
CFG="src/main/config.js"
ISSUER="$(grep -oP "issuerUrl:\s*process\.env\.DTL_OIDC_ISSUER\s*\|\|\s*'\K[^']+" "$CFG")"
REDIRECT_URI="$(grep -oP "redirectUri:\s*process\.env\.DTL_OIDC_REDIRECT\s*\|\|\s*'\K[^']+" "$CFG")"
[[ -n "$ISSUER" && -n "$REDIRECT_URI" ]] || die "could not extract issuer/redirect from $CFG"
ZITADEL_PORT="${ISSUER##*:}"   # e.g. 8090
log "config.js issuer=$ISSUER redirect=$REDIRECT_URI (zitadel port $ZITADEL_PORT)"

# ── Step 1: clean slate (reuses teardown's --for-setup subset — DRY) ─────────────────────────────
log "Step 1/11 — clean slate (removing prior lab containers/volume/runtime-env/app-state)..."
bash "$REPO_ROOT/lab/teardown.sh" --for-setup

# ── Step 2: certs ────────────────────────────────────────────────────────────────────────────────
log "Step 2/11 — generating OpenSSL cert chain..."
bash "$REPO_ROOT/lab/certs/gen-certs.sh" >/dev/null
log "certs generated."

# ── Step 3: NSS provisioning ─────────────────────────────────────────────────────────────────────
log "Step 3/11 — provisioning NSS (CA + client cert/key into ~/.pki/nssdb)..."
bash "$REPO_ROOT/lab/provision-nss.sh" >/dev/null
log "NSS provisioned."

# ── Step 4: nginx on all three ports ─────────────────────────────────────────────────────────────
log "Step 4/11 — starting nginx (:8443 mTLS, :8444 optional+/kill, :8445 CN-gated 403)..."
podman run -d --name dtl-mtls-nginx \
  -p 8443:8443 -p 8444:8444 -p 8445:8445 \
  -v "$REPO_ROOT/lab/nginx/mtls.conf:/etc/nginx/conf.d/default.conf:ro,Z" \
  -v "$REPO_ROOT/lab/certs:/etc/nginx/certs:ro,Z" \
  -v "$REPO_ROOT/lab/kill:/etc/nginx/kill:ro,Z" \
  "$NGINX_IMAGE" >/dev/null
log "nginx up."

# ── Step 5: kill-command = no-op (poller stays quiet during the demo) ────────────────────────────
log "Step 5/11 — initializing kill-command to no-op..."
cp "$REPO_ROOT/lab/kill/kill-none.json" "$REPO_ROOT/lab/kill/kill-command.json"
chmod 644 "$REPO_ROOT/lab/kill/kill-command.json"

# ── Step 6: Postgres (fresh volume — clean init every run, plan Decision 4) ──────────────────────
log "Step 6/11 — starting Postgres (fresh zitadel-db volume)..."
podman run -d --name zitadel-db --network=host \
  -e POSTGRES_USER=root -e POSTGRES_PASSWORD=rootpassword \
  -v zitadel-db:/var/lib/postgresql/data \
  "$POSTGRES_IMAGE" >/dev/null
log "waiting for Postgres..."
for i in $(seq 1 20); do
  if podman exec zitadel-db pg_isready -U root >/dev/null 2>&1; then break; fi
  sleep 2
  (( i == 20 )) && die "Postgres did not become ready in time"
done
log "Postgres ready."

# ── Step 7: Zitadel init + FirstInstance machine SA + PAT (auto-written to a file) ───────────────
log "Step 7/11 — starting Zitadel (start-from-init, seeding machine SA + PAT)..."
mkdir -p "$SEED_DIR"; chmod 777 "$SEED_DIR"   # container (rootless, high uid) must write the PAT here
podman run -d --name zitadel --network=host \
  -v "$SEED_DIR:/pat:Z" \
  -e ZITADEL_DATABASE_POSTGRES_HOST=127.0.0.1 \
  -e ZITADEL_DATABASE_POSTGRES_PORT=5432 \
  -e ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=root \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=rootpassword \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable \
  -e ZITADEL_EXTERNALDOMAIN=127.0.0.1 \
  -e ZITADEL_EXTERNALPORT="$ZITADEL_PORT" \
  -e ZITADEL_EXTERNALSECURE=false \
  -e "ZITADEL_MASTERKEY=$MASTERKEY" \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=admin \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS=admin@localhost.local \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED=true \
  -e "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=Admin12345!" \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED=false \
  -e ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME=zitadel-admin-sa \
  -e ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME=Admin-SA \
  -e ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE=2030-01-01T00:00:00Z \
  -e ZITADEL_FIRSTINSTANCE_PATPATH=/pat/pat.txt \
  "$ZITADEL_IMAGE" \
  start-from-init --masterkeyFromEnv --tlsMode disabled --port "$ZITADEL_PORT" >/dev/null

log "waiting for Zitadel discovery (first-boot migrations, ~60-90s)..."
for i in $(seq 1 36); do
  if curl -sf "$ISSUER/.well-known/openid-configuration" >/dev/null 2>&1; then break; fi
  sleep 5
  (( i == 36 )) && { podman logs --tail 30 zitadel >&2 || true; die "Zitadel did not come up in time"; }
done
log "Zitadel up."

# Assert discovery issuer matches config.js (Decision 13 — catch issuer drift early).
DISC_ISSUER="$(curl -sf "$ISSUER/.well-known/openid-configuration" | python3 -c "import sys,json;print(json.load(sys.stdin)['issuer'])")"
[[ "$DISC_ISSUER" == "$ISSUER" ]] || die "issuer mismatch: discovery='$DISC_ISSUER' config.js='$ISSUER'"
log "discovery issuer matches config.js: $DISC_ISSUER"

# PAT file must exist (FirstInstance writes it on first init).
for i in $(seq 1 10); do
  [[ -s "$PAT_FILE" ]] && break
  sleep 2
  (( i == 10 )) && die "PAT file was not written to $PAT_FILE (FirstInstance machine/PAT env?)"
done
log "PAT seeded ($(wc -c < "$PAT_FILE") bytes)."

# ── Step 8+9: seed Project + Native PKCE App + user, with redirect-match + same-org asserts ──────
log "Step 8-9/11 — seeding Project + Native PKCE App + testuser via Management API..."
CLIENT_ID="$(bash "$REPO_ROOT/lab/zitadel/seed-zitadel.sh" "$PAT_FILE" "$ISSUER" "$REDIRECT_URI")"
[[ -n "$CLIENT_ID" ]] || die "seed-zitadel.sh returned no client_id"
log "seeded client_id: $CLIENT_ID"

# ── Step 10: write runtime-env (fresh client_id + absolute CA path — plan Decisions 2,3) ─────────
log "Step 10/11 — writing $RUNTIME_ENV ..."
cat > "$RUNTIME_ENV" <<EOF
# Generated by lab/setup.sh — per-machine, git-ignored, DO NOT COMMIT.
# 'source' this before launching the app so the packaged binary picks up the fresh
# client_id + absolute kill-CA path at RUNTIME (build-time .env is irrelevant to a .deb).
export DTL_OIDC_CLIENT_ID=$CLIENT_ID
export DTL_KILL_CA_PATH=$CA_ABS
EOF
chmod 600 "$RUNTIME_ENV"
log "runtime-env written."

# ── Step 11: summary ─────────────────────────────────────────────────────────────────────────────
cat <<EOF

[setup] ============================================================
[setup] DONE. Lab is up and seeded — zero console interaction.
[setup]   Zitadel : $ISSUER  (user: testuser@dtl.local / Test1234!)
[setup]   client_id: $CLIENT_ID
[setup]   nginx   : :8443 (tool-1)  :8444 (/kill)  :8445 (tool-2 403)
[setup]
[setup] Curl-verify the three ports (with the test cert):
[setup]   cd lab/certs
[setup]   curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/ | grep verify=
[setup]   curl -s -o /dev/null -w '%{http_code}\\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/   # 403
[setup]   curl -s --cacert ca.pem https://localhost:8444/     # verify=NONE
[setup]
[setup] Launch the app (NoMachine DESKTOP terminal — one command, no keyring dialog of any kind):
[setup]   bash lab/run-app.sh
[setup]   # sources lab/.runtime-env + bootstraps/unlocks the keyring silently (empty pw) — zero prompts.
[setup]   # packaged .deb: set DTL_APP_BIN to the unpacked binary path, then run lab/run-app.sh
[setup] ============================================================
EOF
