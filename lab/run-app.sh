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
  echo "[run-app] lab/.runtime-env not found - run 'bash lab/setup.sh' first." >&2
  exit 1
fi

# Launch target auto-detection, in priority order:
#   1. DTL_APP_BIN, if set - explicit override (e.g. a non-default unpack location).
#   2. The unpacked packaged .deb at ~/dtl-app-installed, if present - the normal user path.
#   3. The dev source tree (node_modules/.bin/electron .) - the normal developer path.
# APP_BIN/APP_ARGS are passed to the inner bash -c as separate positional parameters, not
# spliced into the script text, so a path containing a space (like "DTL App") needs no manual
# quoting from the caller - bash's own argument passing keeps it intact as one value.
PACKAGED_BIN="$HOME/dtl-app-installed/opt/DTL App/dtl-app"
if [[ -n "${DTL_APP_BIN:-}" ]]; then
  APP_BIN="$DTL_APP_BIN"
  APP_ARGS=()
  echo "[run-app] launch mode: override - $APP_BIN"
elif [[ -x "$PACKAGED_BIN" ]]; then
  APP_BIN="$PACKAGED_BIN"
  APP_ARGS=()
  echo "[run-app] launch mode: packaged .deb - $APP_BIN"
else
  APP_BIN="./node_modules/.bin/electron"
  APP_ARGS=(".")
  echo "[run-app] launch mode: dev source - $APP_BIN"
fi
ENSURE_KEYRING="$REPO_ROOT/lab/ensure-keyring.py"

exec dbus-run-session -- bash -c '
  eval $(echo -n "" | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)
  python3 "$1" || exit 1
  shift
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 exec "$@"
' bash "$ENSURE_KEYRING" "$APP_BIN" "${APP_ARGS[@]}"
