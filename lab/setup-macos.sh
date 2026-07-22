#!/usr/bin/env bash
# setup-macos.sh - macOS equivalent of lab/setup.sh. Native processes instead of containers
# (podman/containers are not possible on the target hardware - no nested virtualization). See
# docs/internal/M6-macos-integration.md for the full rationale and verified-inputs behind every
# decision in this script.
#
# NEVER edits lab/setup.sh, lab/teardown.sh, or lab/run-app.sh - those are verified Linux paths
# and this script exists specifically so nothing here can regress them.
#
# WARNING: ONE-WAY DOOR, same as setup.sh - the clean-slate step destroys any existing Zitadel/
# Postgres/Apache state on this machine and re-seeds from scratch. Irreversible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ZITADEL_VERSION="v2.71.10"   # pinned - same version as setup.sh's ZITADEL_IMAGE
ZITADEL_BIN_DIR="$REPO_ROOT/lab/.zitadel-bin"      # per-machine, git-ignored, persists across runs
ZITADEL_BIN="$ZITADEL_BIN_DIR/zitadel"
ZITADEL_RUNTIME_DIR="$REPO_ROOT/lab/.zitadel-runtime"
ZITADEL_PID_FILE="$ZITADEL_RUNTIME_DIR/zitadel.pid"
ZITADEL_LOG="$ZITADEL_RUNTIME_DIR/zitadel.log"

APACHE_RUNTIME_DIR="$REPO_ROOT/lab/.apache-runtime"
APACHE_CONF="$APACHE_RUNTIME_DIR/httpd.conf"
APACHE_PIDFILE="$APACHE_RUNTIME_DIR/httpd.pid"

# Pinned to 16 deliberately, NOT "latest" - confirmed the hard way during Step 1 implementation.
# PG 18 (what "latest" resolves to on a current Postgres.app install) hits a real, confirmed
# upstream Zitadel bug: migration 34_add_cache_schema fails with "ERROR: partitioned tables
# cannot be unlogged" (PostgreSQL 18 enforces a rule earlier versions didn't). The fix
# (zitadel/zitadel PR #11484) exists but was backported to v4+ only - this project pins
# v2.71.10 deliberately (see lab/zitadel/README.md: v4+ breaks the single-container console),
# so bumping Zitadel to pick up the fix isn't an option. PG16 has no such issue and matches the
# postgres:16-alpine pin on Linux exactly - download Postgres.app's PG16-specific installer
# (NOT the "all currently supported versions" bundle, which currently defaults its Versions/
# dir to whatever is newest - confirmed on this machine it was PG18-only for that download).
PGBIN="/Applications/Postgres.app/Contents/Versions/16/bin"
PGDATA="$REPO_ROOT/lab/.postgres-data"                          # per-machine, git-ignored, wiped every run

MASTERKEY="MasterkeyNeedsToHave32Characters"   # exactly 32 chars - throwaway local value, same as setup.sh
SEED_DIR="$REPO_ROOT/lab/zitadel/.seed"
PAT_FILE="$SEED_DIR/pat.txt"
RUNTIME_ENV="$REPO_ROOT/lab/.runtime-env"
CA_ABS="$REPO_ROOT/lab/certs/ca.pem"

# Target app path the two security commands will reference. Defaults to the real, documented
# post-.dmg-install location (Step 6's setup guide installs here before running this script -
# security import -T requires its target to already exist, confirmed empirically - see the M6
# plan's D-M6-10). Overridable during development, before Step 5's packaging exists, to point at
# a dev build instead - same override pattern lab/run-app.sh already uses for DTL_APP_BIN.
DTL_APP_BIN_PATH="${DTL_APP_BIN_PATH:-/Applications/DTL App.app/Contents/MacOS/DTL App}"

log()  { echo "[setup-macos] $*"; }
die()  { echo "[setup-macos] ERROR: $*" >&2; exit 1; }

# Step 0: preflight - prerequisites are checked, never installed (no sudo assumed, except the two
# security commands at the very end, which need a real GUI session, not this script).
log "Step 0/11 - preflight prerequisite check..."
MISSING=()
for bin in openssl curl python3 node npm security; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
[[ -x /usr/sbin/httpd ]] || MISSING+=("/usr/sbin/httpd (should ship with macOS)")
[[ -x /usr/libexec/apache2/mod_ssl.so ]] || MISSING+=("mod_ssl.so (should ship with macOS)")
[[ -x "$PGBIN/initdb" && -x "$PGBIN/pg_ctl" ]] || MISSING+=("Postgres.app with PostgreSQL 16 specifically (postgresapp.com/downloads.html - the 'PostgreSQL 16' download, NOT 'all currently supported versions' or the PG18-only one - see setup-guide-macos.md)")
if (( ${#MISSING[@]} )); then
  echo "[setup-macos] MISSING PREREQUISITES: ${MISSING[*]}" >&2
  die "prerequisites missing - nothing was changed. Install the above and re-run."
fi
log "all prerequisites present."

# config.js is the SINGLE SOURCE OF TRUTH for issuer + redirect - same extraction setup.sh does.
CFG="src/main/config.js"
ISSUER="$(grep -oE "issuerUrl:[[:space:]]*process\.env\.DTL_OIDC_ISSUER[[:space:]]*\|\|[[:space:]]*'[^']+'" "$CFG" | sed -E "s/.*'([^']+)'/\1/")"
REDIRECT_URI="$(grep -oE "redirectUri:[[:space:]]*process\.env\.DTL_OIDC_REDIRECT[[:space:]]*\|\|[[:space:]]*'[^']+'" "$CFG" | sed -E "s/.*'([^']+)'/\1/")"
DEVICE_CN="$(grep -oE "CERT_SUBJECT_CN = process\.env\.DTL_CERT_CN \|\| '[^']+'" "$CFG" | sed -E "s/.*'([^']+)'/\1/")"
[[ -n "$ISSUER" && -n "$REDIRECT_URI" && -n "$DEVICE_CN" ]] || die "could not extract issuer/redirect/device CN from $CFG"
ZITADEL_PORT="${ISSUER##*:}"
log "config.js issuer=$ISSUER redirect=$REDIRECT_URI device=$DEVICE_CN (zitadel port $ZITADEL_PORT)"

# Step 1: clean slate. Inlined here rather than delegated to teardown-macos.sh --for-setup (the
# Linux pattern) because teardown-macos.sh doesn't exist yet in this incremental rollout - will be
# refactored to call it once Step 2 lands, same DRY relationship setup.sh has with teardown.sh.
log "Step 1/11 - clean slate (stopping prior Apache/Zitadel, wiping Postgres data dir + runtime-env)..."
if [[ -f "$APACHE_PIDFILE" ]]; then
  /usr/sbin/httpd -f "$APACHE_CONF" -k stop >/dev/null 2>&1 || true
  sleep 1
fi
if [[ -f "$ZITADEL_PID_FILE" ]]; then
  kill "$(cat "$ZITADEL_PID_FILE")" >/dev/null 2>&1 || true
  sleep 1
fi
if [[ -x "$PGBIN/pg_ctl" && -d "$PGDATA" ]]; then
  "$PGBIN/pg_ctl" -D "$PGDATA" stop -m fast >/dev/null 2>&1 || true
fi
rm -rf "$PGDATA" "$APACHE_RUNTIME_DIR" "$ZITADEL_RUNTIME_DIR" "$RUNTIME_ENV" "$SEED_DIR"
mkdir -p "$APACHE_RUNTIME_DIR" "$ZITADEL_RUNTIME_DIR"
log "clean slate done."

log "Step 2/11 - generating OpenSSL cert chain (lab/certs/gen-certs.sh, unchanged - pure openssl, no platform-specific calls)..."
bash "$REPO_ROOT/lab/certs/gen-certs.sh" >/dev/null
log "certs generated."

log "Step 3/11 - generating Apache config from template and starting httpd (:8443 mTLS, :8444 optional+/kill, :8445 CN-gated 403)..."
sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$REPO_ROOT/lab/apache/httpd.conf.template" > "$APACHE_CONF"
/usr/sbin/httpd -f "$APACHE_CONF" -t || die "Apache config failed syntax check"
/usr/sbin/httpd -f "$APACHE_CONF" -k start || die "Apache failed to start - check $APACHE_RUNTIME_DIR/error.log"
sleep 1
log "Apache up."

# Step 4: kill-switch keypair - identical to setup.sh (gen-keypair.sh/sign-command.sh are plain
# Node scripts, no platform-specific calls).
log "Step 4/11 - generating a fresh kill-switch signing keypair..."
rm -f "$REPO_ROOT/lab/kill/kill-signing.key" "$REPO_ROOT/lab/kill/kill-signing.pub"
bash "$REPO_ROOT/lab/kill/gen-keypair.sh" >/dev/null
KILL_PUB_PEM="$(cat "$REPO_ROOT/lab/kill/kill-signing.pub")"
[[ -n "$KILL_PUB_PEM" ]] || die "kill-signing.pub was not generated"
log "keypair generated."

log "signing a fresh no-op kill-command..."
bash "$REPO_ROOT/lab/kill/sign-command.sh" "$DEVICE_CN" cmd-noop none 2>/dev/null > "$REPO_ROOT/lab/kill/kill-command.json"
chmod 644 "$REPO_ROOT/lab/kill/kill-command.json"
log "active kill-command initialized (no-op, signed with the fresh key). Apache's :8444 /kill Alias points at this same file."

# Step 5: Postgres - full clean-slate every run (rm -rf + fresh initdb), the literal equivalent
# of Linux's `podman volume rm zitadel-db`, via Postgres.app's bundled binaries directly. The GUI
# app is never launched - see D-M6-3/D-M6-8 in the M6 plan. -U root matches setup.sh's
# ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME exactly, so no env-var remapping is needed below.
# --locale=C: this box's shell locale (LANG/LC_*) is set to something initdb considers invalid
# (confirmed - it refuses outright rather than warning, unlike other tools on this VM that just
# warn and fall back). C is always valid and side-steps the broken system locale entirely; a lab
# database has no need for locale-aware collation.
log "Step 5/11 - starting Postgres (fresh data dir, every run)..."
"$PGBIN/initdb" -D "$PGDATA" -U root -A trust --locale=C >/dev/null
"$PGBIN/pg_ctl" -D "$PGDATA" -l "$ZITADEL_RUNTIME_DIR/postgres.log" -o "-p 5432" start >/dev/null
log "waiting for Postgres..."
for i in $(seq 1 20); do
  if "$PGBIN/pg_isready" -U root -p 5432 >/dev/null 2>&1; then break; fi
  sleep 1
  (( i == 20 )) && die "Postgres did not become ready in time"
done
log "Postgres ready."

# Step 6: download Zitadel if not already cached (binary is immutable/reusable across runs,
# unlike the database above which must be wiped every run - same reasoning podman's own image
# cache already gets on Linux, just no daemon managing it here).
if [[ ! -x "$ZITADEL_BIN" ]]; then
  log "Step 6/11 - downloading Zitadel $ZITADEL_VERSION (darwin-amd64, not cached yet)..."
  mkdir -p "$ZITADEL_BIN_DIR"
  curl -sSL "https://github.com/zitadel/zitadel/releases/download/$ZITADEL_VERSION/zitadel-darwin-amd64.tar.gz" \
    -o "$ZITADEL_BIN_DIR/zitadel.tar.gz"
  # The release tarball extracts into a zitadel-darwin-amd64/ subdirectory, not flat - confirmed
  # by actually inspecting it, not assumed. Extract to a temp subdir and move the binary up so
  # ZITADEL_BIN's flat path stays simple for the rest of this script.
  tar -xzf "$ZITADEL_BIN_DIR/zitadel.tar.gz" -C "$ZITADEL_BIN_DIR"
  mv "$ZITADEL_BIN_DIR/zitadel-darwin-amd64/zitadel" "$ZITADEL_BIN"
  rm -rf "$ZITADEL_BIN_DIR/zitadel.tar.gz" "$ZITADEL_BIN_DIR/zitadel-darwin-amd64"
  chmod +x "$ZITADEL_BIN"
  [[ -x "$ZITADEL_BIN" ]] || die "zitadel binary not found after extraction"
  log "Zitadel binary ready."
else
  log "Step 6/11 - Zitadel $ZITADEL_VERSION binary already cached, skipping download."
fi

# Step 7: Zitadel init + FirstInstance machine SA + PAT. Same 21 env vars as setup.sh's podman
# invocation - only ZITADEL_FIRSTINSTANCE_PATPATH changes shape (container mount path -> a real
# host path directly, no translation logic needed beyond that).
log "Step 7/11 - starting Zitadel (start-from-init, seeding machine SA + PAT)..."
mkdir -p "$SEED_DIR"
ZITADEL_DATABASE_POSTGRES_HOST=127.0.0.1 \
ZITADEL_DATABASE_POSTGRES_PORT=5432 \
ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel \
ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel \
ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=zitadel \
ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable \
ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=root \
ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=rootpassword \
ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable \
ZITADEL_EXTERNALDOMAIN=127.0.0.1 \
ZITADEL_EXTERNALPORT="$ZITADEL_PORT" \
ZITADEL_EXTERNALSECURE=false \
ZITADEL_MASTERKEY="$MASTERKEY" \
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=admin \
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS=admin@localhost.local \
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED=true \
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD='Admin12345!' \
ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED=false \
ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME=zitadel-admin-sa \
ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME=Admin-SA \
ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE=2030-01-01T00:00:00Z \
ZITADEL_FIRSTINSTANCE_PATPATH="$PAT_FILE" \
  "$ZITADEL_BIN" start-from-init --masterkeyFromEnv --tlsMode disabled --port "$ZITADEL_PORT" \
  > "$ZITADEL_LOG" 2>&1 &
echo $! > "$ZITADEL_PID_FILE"

log "waiting for Zitadel discovery (first-boot migrations, ~60-90s)..."
for i in $(seq 1 36); do
  if curl -sf "$ISSUER/.well-known/openid-configuration" >/dev/null 2>&1; then break; fi
  sleep 5
  (( i == 36 )) && { tail -n 30 "$ZITADEL_LOG" >&2 || true; die "Zitadel did not come up in time"; }
done
log "Zitadel up."

DISC_ISSUER="$(curl -sf "$ISSUER/.well-known/openid-configuration" | python3 -c "import sys,json;print(json.load(sys.stdin)['issuer'])")"
[[ "$DISC_ISSUER" == "$ISSUER" ]] || die "issuer mismatch: discovery='$DISC_ISSUER' config.js='$ISSUER'"
log "discovery issuer matches config.js: $DISC_ISSUER"

for i in $(seq 1 10); do
  [[ -s "$PAT_FILE" ]] && break
  sleep 2
  (( i == 10 )) && die "PAT file was not written to $PAT_FILE (FirstInstance machine/PAT env?)"
done
log "PAT seeded ($(wc -c < "$PAT_FILE") bytes)."

# Step 8-9: seed Project + Native PKCE App + user - lab/zitadel/seed-zitadel.sh unchanged
# (pure curl against the issuer URL + a PAT file path, no container assumptions - verified in
# the M6 plan's research phase).
log "Step 8-9/11 - seeding Project + Native PKCE App + testuser via Management API..."
CLIENT_ID="$(bash "$REPO_ROOT/lab/zitadel/seed-zitadel.sh" "$PAT_FILE" "$ISSUER" "$REDIRECT_URI")"
[[ -n "$CLIENT_ID" ]] || die "seed-zitadel.sh returned no client_id"
log "seeded client_id: $CLIENT_ID"

# Step 10: write runtime-env - same shape as setup.sh's.
log "Step 10/11 - writing $RUNTIME_ENV ..."
cat > "$RUNTIME_ENV" <<EOF
# Generated by lab/setup-macos.sh - per-machine, git-ignored, DO NOT COMMIT.
export DTL_OIDC_CLIENT_ID=$CLIENT_ID
export DTL_KILL_CA_PATH=$CA_ABS
export DTL_KILL_PUBLIC_KEY_PEM="$KILL_PUB_PEM"
EOF
chmod 600 "$RUNTIME_ENV"
log "runtime-env written."

# Step 11: hand over the two commands that need a real GUI session (security import cannot run
# over SSH at all - confirmed - "User interaction is not allowed"). -T requires its target binary
# to already exist (confirmed empirically - see M6 plan D-M6-10), so check for it and give a
# clear message rather than handing over a command that will fail confusingly.
log "Step 11/11 - cert provisioning (needs your GUI session - cannot be automated)..."
if [[ ! -x "$DTL_APP_BIN_PATH" ]]; then
  cat <<EOF

[setup-macos] NOTE: "$DTL_APP_BIN_PATH" does not exist yet.
[setup-macos]   security import's -T flag requires its target binary to already exist - install
[setup-macos]   the app (or set DTL_APP_BIN_PATH to a dev build) before running the command below,
[setup-macos]   or it will fail with "SecTrustedApplicationCreateFromPath: No such file or directory".
EOF
fi

cat <<EOF

[setup-macos] ============================================================
[setup-macos] Lab is up. Two commands need to run in a real Terminal.app session (not SSH):
[setup-macos]
[setup-macos]   security import "$REPO_ROOT/lab/certs/client.p12" \\
[setup-macos]     -k ~/Library/Keychains/login.keychain-db \\
[setup-macos]     -P dtltest \\
[setup-macos]     -T "$DTL_APP_BIN_PATH"
[setup-macos]
[setup-macos]   security add-trusted-cert -r trustRoot -p ssl \\
[setup-macos]     -k ~/Library/Keychains/login.keychain-db \\
[setup-macos]     "$REPO_ROOT/lab/certs/ca.pem"
[setup-macos]
[setup-macos] Expect at most one confirmation click on the import - not guaranteed zero.
[setup-macos]
[setup-macos]   Zitadel : $ISSUER  (user: testuser@dtl.local / Test1234!)
[setup-macos]   client_id: $CLIENT_ID
[setup-macos]   Apache  : :8443 (tool-1)  :8444 (/kill)  :8445 (tool-2 403)
[setup-macos]   kill switch: fresh signing keypair generated (lab/kill/kill-signing.key); sign new
[setup-macos]     commands with: bash lab/kill/sign-command.sh $DEVICE_CN <cmd-id> wipe 2>/dev/null > lab/kill/kill-command.json
[setup-macos]
[setup-macos] Curl-verify the three ports (with the test cert):
[setup-macos]   cd lab/certs
[setup-macos]   curl -s -o /dev/null -w '%{http_code}\\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/
[setup-macos]   curl -s -o /dev/null -w '%{http_code}\\n' --cacert ca.pem https://localhost:8443/                                    # 400
[setup-macos]   curl -s -o /dev/null -w '%{http_code}\\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/  # 403
[setup-macos]   curl -s -o /dev/null -w '%{http_code}\\n' --cacert ca.pem https://localhost:8444/
[setup-macos]   curl -s --cacert ca.pem https://localhost:8444/kill
[setup-macos] ============================================================
EOF
