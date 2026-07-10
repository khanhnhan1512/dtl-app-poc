#!/usr/bin/env bash
# run-app.sh - launch the DTL App with the correct runtime env + a SILENT keyring bootstrap+unlock.
#
# WARNING: MUST be run from the NoMachine DESKTOP terminal (needs the session DISPLAY) - not over SSH.
#
# Single source of truth for the launch wrapper (DRY): all docs point here so the subtle
# dbus-run-session + keyring incantation lives in exactly ONE place.
#
# Why this needs TWO steps, not just --unlock (empirically verified - do not "simplify"):
# safeStorage encrypts tokens.enc with an OS-keyring-backed key (backend: gnome_libsecret). On a
# NoMachine session the login keyring is locked (or, after lab/teardown.sh, absent entirely), so a
# plain `gnome-keyring-daemon --start` pops an interactive "Unlock Keyring" dialog.
#
# `gnome-keyring-daemon --unlock` only UNLOCKS an EXISTING collection - it does NOT create one.
# Confirmed on the VM: on a machine with no default collection yet, `--unlock ""` alone leaves
# `ReadAlias('default')` empty, and the app's first secret-store then hits the Secret Service's
# normal `CreateCollection` path, which requires the interactive `gcr-prompter` GUI ("Choose password
# for NEW keyring" - the dialog this fix removes). So we ALSO run `lab/ensure-keyring.py`, which
# calls the legacy `CreateWithMasterPassword` D-Bus method to create an EMPTY-password default
# collection with NO prompt at all, before the app ever touches safeStorage. Verified end-to-end
# (fresh box, ~/.local/share/keyrings/ removed entirely) across multiple independent relaunch cycles:
# zero prompts, secrets store and read back correctly every time.
#
# DO NOT replace any of this with `--password-store=basic`: that bypasses the OS keyring entirely
# and DOWNGRADES token encryption (the app stops using gnome_libsecret). We remove only the PROMPT
# (an environment property), never the encryption (an app feature).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Fresh client_id + absolute kill-CA path (written by lab/setup.sh).
if [[ -f lab/.runtime-env ]]; then
  # shellcheck disable=SC1091
  source lab/.runtime-env
else
  echo "[run-app] lab/.runtime-env not found — run 'bash lab/setup.sh' first." >&2
  exit 1
fi

# Launch target: dev binary by default; override with DTL_APP_BIN for a packaged .deb, e.g.
#   DTL_APP_BIN="\"$HOME/dtl-app-installed/opt/DTL App/dtl-app\"" bash lab/run-app.sh
# Note the escaped inner \" quotes AND the outer double quotes (not single) - $APP_BIN is spliced
# unquoted into a bash -c string below, so a path containing a space (like "DTL App") needs its
# OWN literal quote characters embedded in the value to survive that re-parse. Single-quoting the
# whole assignment would also stop $HOME from expanding - confirmed both failure modes empirically.
APP_BIN="${DTL_APP_BIN:-./node_modules/.bin/electron .}"
ENSURE_KEYRING="$REPO_ROOT/lab/ensure-keyring.py"

exec dbus-run-session -- bash -c "
  eval \$(echo -n '' | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)
  python3 '$ENSURE_KEYRING' || exit 1
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 $APP_BIN
"
