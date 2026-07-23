#!/usr/bin/env bash
# run-app-macos.sh - launch the DTL App with the correct runtime env.
#
# Unlike Linux's run-app.sh, no keyring bootstrap is needed here: safeStorage on macOS talks to
# Keychain directly via the OS, so there's no dbus-run-session / gnome-keyring-daemon /
# ensure-keyring.py dance to reproduce. See docs/internal/M6-macos-integration.md Step 4.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f lab/.runtime-env ]]; then
  # set -a: .runtime-env's lines are already `export KEY=value` (setup-macos.sh writes them that
  # way), but a plain `source` still only re-exports what's already exported - if that detail ever
  # changes, a bare `source` would silently leave client_id/kill-pubkey as shell-only variables,
  # invisible to the exec'd app below. set -a makes every assignment sourced here an environment
  # variable regardless, so this doesn't depend on that detail holding.
  set -a
  # shellcheck disable=SC1091
  source lab/.runtime-env
  set +a
else
  echo "[run-app-macos] lab/.runtime-env not found - run 'bash lab/setup-macos.sh' first." >&2
  exit 1
fi

# Launch target auto-detection, in priority order:
#   1. DTL_APP_BIN, if set - same override var lab/run-app.sh uses on Linux. Both scripts launch
#      the app, so both take the same variable name (DTL_APP_BIN_PATH is a different concept -
#      setup-macos.sh's -T target - accepted here only as a fallback for convenience).
#   2. DTL_APP_BIN_PATH, if set - fallback alias, see above.
#   3. The default installed location - normal path once Step 5 (.dmg) ships.
#   4. The dev source tree (node_modules/.bin/electron .) - fallback if neither above exists.
DEFAULT_BIN="/Applications/DTL App.app/Contents/MacOS/DTL App"
if [[ -n "${DTL_APP_BIN:-}" ]]; then
  APP_BIN="$DTL_APP_BIN"
  APP_ARGS=()
  echo "[run-app-macos] launch mode: override (DTL_APP_BIN) - $APP_BIN"
elif [[ -n "${DTL_APP_BIN_PATH:-}" ]]; then
  APP_BIN="$DTL_APP_BIN_PATH"
  APP_ARGS=()
  echo "[run-app-macos] launch mode: override (DTL_APP_BIN_PATH) - $APP_BIN"
elif [[ -x "$DEFAULT_BIN" ]]; then
  APP_BIN="$DEFAULT_BIN"
  APP_ARGS=()
  echo "[run-app-macos] launch mode: installed .app - $APP_BIN"
else
  APP_BIN="./node_modules/.bin/electron"
  APP_ARGS=(".")
  echo "[run-app-macos] launch mode: dev source - $APP_BIN"
fi

# macOS's stock bash (3.2 - Apple ships no newer GPLv2 build) throws "unbound variable" under
# set -u when expanding an EMPTY array with "${arr[@]}" (fixed upstream in bash 4.4+, not present
# here) - so branch on length instead of expanding APP_ARGS directly when it's empty.
if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
  exec "$APP_BIN" "${APP_ARGS[@]}"
else
  exec "$APP_BIN"
fi
