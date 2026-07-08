#!/usr/bin/env python3
# ensure-keyring.py — idempotent: guarantee the OS 'default' Secret Service collection exists,
# has an EMPTY password, and is unlocked, WITHOUT ever showing a GUI dialog.
#
# ── Why this exists (do not delete / "simplify" away) ────────────────────────────────────────────
# `gnome-keyring-daemon --unlock ""` only UNLOCKS an *existing* collection — it does NOT create one.
# On a machine where no default keyring has ever been created (a fresh handoff box, or right after
# lab/teardown.sh clears it), safeStorage's first write finds NO default collection and the daemon's
# normal client path (Secret Service `CreateCollection`) requires an interactive GTK prompt
# (`gcr-prompter`) — the exact "Choose password for NEW keyring" dialog this script exists to avoid.
#
# The fix: call the legacy `org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface
# .CreateWithMasterPassword` method directly. It creates a collection with a caller-supplied
# password (here: empty) with NO prompt involved at all — confirmed empirically on this VM
# (gnome-keyring-daemon 46.1): a probe script created the collection, aliased it 'default', and
# stored+read back a real secret with zero prompts, across multiple independent daemon restarts and
# even with ~/.local/share/keyrings/ removed entirely (true fresh-machine case).
#
# Run this ONCE per launch, inside the SAME dbus-run-session as the app (see lab/run-app.sh), right
# after starting the daemon and before the app's first safeStorage call. Idempotent: no-ops if a
# working default collection already exists.
#
# Requires: python3-dbus (preflight-checked by lab/setup.sh). NOT app code — pure launch-environment
# tooling, mirrors exactly what libsecret/Electron's safeStorage does at the D-Bus level.
import sys

try:
    import dbus
except ImportError:
    print(
        "[ensure-keyring] FATAL: python3-dbus not installed (see lab/setup.sh preflight)",
        file=sys.stderr,
    )
    sys.exit(1)


def die(msg):
    print(f"[ensure-keyring] FATAL: {msg}", file=sys.stderr)
    sys.exit(1)


bus = dbus.SessionBus()
service = bus.get_object("org.freedesktop.secrets", "/org/freedesktop/secrets")
service_iface = dbus.Interface(service, "org.freedesktop.Secret.Service")

_output, session_path = service_iface.OpenSession("plain", dbus.String(""))

collection_path = service_iface.ReadAlias("default")

if str(collection_path) == "/":
    print(
        "[ensure-keyring] no default collection -- creating (empty password, no prompt)",
        file=sys.stderr,
    )
    legacy = dbus.Interface(service, "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface")
    attrs = dbus.Dictionary(
        {
            "org.freedesktop.Secret.Collection.Label": dbus.String(
                "Default keyring", variant_level=1
            )
        },
        signature="sv",
    )
    empty_secret = dbus.Struct(
        (session_path, dbus.ByteArray(b""), dbus.ByteArray(b""), dbus.String("text/plain")),
        signature="oayays",
    )
    try:
        collection_path = legacy.CreateWithMasterPassword(attrs, empty_secret)
    except dbus.exceptions.DBusException as e:
        die(f"CreateWithMasterPassword failed: {e}")
    service_iface.SetAlias("default", collection_path)
    print(f"[ensure-keyring] created + aliased 'default': {collection_path}", file=sys.stderr)
else:
    print(f"[ensure-keyring] default collection already exists: {collection_path}", file=sys.stderr)

collection = bus.get_object("org.freedesktop.secrets", collection_path)
props_iface = dbus.Interface(collection, "org.freedesktop.DBus.Properties")
if props_iface.Get("org.freedesktop.Secret.Collection", "Locked"):
    print("[ensure-keyring] locked -- unlocking with empty password", file=sys.stderr)
    _unlocked, prompt = service_iface.Unlock([collection_path])
    if str(prompt) not in ("/", ""):
        die(
            "unlock required a prompt — the collection's password is not empty (was it created "
            "interactively with a real password? clear ~/.local/share/keyrings/ via lab/teardown.sh)"
        )

print("[ensure-keyring] OK -- default collection ready, unlocked, zero prompts", file=sys.stderr)
