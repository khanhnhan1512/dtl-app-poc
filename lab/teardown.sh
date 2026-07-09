#!/usr/bin/env bash
# teardown.sh — remove everything the DTL App / test lab created, returning the machine to a
# "never ran DTL App" state. Idempotent: safe to run on an already-clean box.
#
# NEVER removes prerequisites (node, podman, libnss3-tools, openssl, keyring) — those outlive
# teardown by design and are preflight-checked by setup.sh. See plans/handoff-prep-spike.md.
#
# Modes:
#   teardown.sh              full teardown (default) — everything below.
#   teardown.sh --for-setup  clean-slate subset used by setup.sh: containers + zitadel-db volume +
#                            runtime-env + PAT seed + app state (tokens.enc, kill-ledger). Leaves the
#                            regenerable certs/NSS (setup re-creates them) and the unpacked .deb alone.
set -uo pipefail   # NOT -e: teardown must push through missing pieces (idempotent)

MODE="${1:-full}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NSS_DB="sql:$HOME/.pki/nssdb"
CLIENT_CN="DTL-Ubuntu-Test-Device"
CA_NICK="DTL-Test-Root-CA"
APP_STATE_DIR="$HOME/.config/DTL App"
DEB_INSTALL_DIR="${DTL_DEB_INSTALL_DIR:-$HOME/dtl-app-installed}"

log() { echo "[teardown] $*"; }

# ── Always (both modes): containers, zitadel-db volume, runtime-env, PAT seed, app state ──────────
# NOTE: remove containers/volumes ONE AT A TIME. On this podman, a single `rm -f A B C D` where some
# names don't exist returns 0 but silently removes NOTHING (confirmed on the VM). Per-name is robust.
log "removing containers (nginx, zitadel, postgres, any probe leftovers)..."
for c in dtl-mtls-nginx zitadel zitadel-db zt-probe zt-probe-db; do
  podman rm -f "$c" >/dev/null 2>&1 || true
done

log "removing zitadel-db volume (clean slate for next init)..."
for v in zitadel-db zt-probe-db; do
  podman volume rm "$v" >/dev/null 2>&1 || true
done

log "removing runtime-env + Zitadel PAT seed..."
rm -f  "$REPO_ROOT/lab/.runtime-env"
rm -rf "$REPO_ROOT/lab/zitadel/.seed"

log "removing app state (tokens.enc, kill-ledger.json)..."
rm -f "$APP_STATE_DIR/tokens.enc" "$APP_STATE_DIR/kill-ledger.json"

# Clear the OS login keyring so the next launch starts from a genuinely clean keyring state.
# lab/run-app.sh's `ensure-keyring.py` step (NOT --unlock alone — --unlock only unlocks an
# EXISTING collection, confirmed empirically) recreates an empty-password default collection
# non-interactively either way, so this removal is not strictly required for prompt-freeness — but
# it IS part of the same auth-state reset as tokens.enc above: safeStorage encrypts tokens.enc with
# a keyring-backed key, so a fresh token round-trips cleanest against a fresh keyring too.
# ⚠️ WARNING: this deletes ~/.local/share/keyrings/ — on a real desktop that discards ALL saved
#    passwords. That is acceptable ONLY because this is a dedicated per-machine lab box (fresh-machine
#    handoff assumption). It does NOT weaken encryption — safeStorage still uses gnome_libsecret.
log "clearing OS login keyring (ensure-keyring.py recreates it prompt-free on next launch)..."
rm -f "$HOME/.local/share/keyrings/"*.keyring "$HOME/.local/share/keyrings/default"

if [[ "$MODE" == "--for-setup" ]]; then
  log "clean-slate (--for-setup) done — certs/NSS/.deb left in place (setup re-creates certs/NSS)."
  exit 0
fi

# ── Full teardown only: NSS entries, generated certs/keys, kill signing key, unpacked .deb ────────
log "removing NSS entries (client cert+key, CA)..."
certutil -F -n "$CLIENT_CN" -d "$NSS_DB" >/dev/null 2>&1 || true
certutil -D -n "$CA_NICK"   -d "$NSS_DB" >/dev/null 2>&1 || true

log "removing generated certs/keys (lab/certs)..."
rm -f "$REPO_ROOT"/lab/certs/{ca,server,client}.{key,crt,pem,p12,srl,csr}

log "removing kill signing keypair + resetting active kill-command..."
# Both halves removed: the public key is now a per-machine artifact regenerated fresh by
# setup.sh (Decision 16) and env-injected via DTL_KILL_PUBLIC_KEY_PEM, not a fixed shipped
# fixture — leaving a stale kill-signing.pub around after a full teardown would silently
# mismatch whatever key setup.sh generates next.
rm -f "$REPO_ROOT/lab/kill/kill-signing.key" "$REPO_ROOT/lab/kill/kill-signing.pub"
# Best-effort placeholder only — this committed fixture is signed with the ORIGINAL fixed dev
# key and won't verify against a freshly generated one anyway; setup.sh overwrites this file
# with a freshly-signed no-op in its own Step 5 regardless.
if [[ -f "$REPO_ROOT/lab/kill/kill-none.json" ]]; then
  cp "$REPO_ROOT/lab/kill/kill-none.json" "$REPO_ROOT/lab/kill/kill-command.json" 2>/dev/null || true
fi

log "removing unpacked .deb install dir ($DEB_INSTALL_DIR) if present..."
rm -rf "$DEB_INSTALL_DIR"

log "DONE — VM returned to 'never ran DTL App' state."
log "NOTE: prerequisites (node, podman, libnss3-tools, openssl, keyring) were intentionally left in place."
