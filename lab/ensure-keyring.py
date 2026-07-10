#!/usr/bin/env python3
"""ensure-keyring.py - make sure the OS 'default' Secret Service keyring exists, is unlocked,
and has an empty password, without ever popping a GUI dialog.

Run once per launch, inside the same D-Bus session as the app (see lab/run-app.sh), right
before the app's first safeStorage call. Idempotent - does nothing if a working default
collection already exists.

Requires python3-dbus (checked by lab/setup.sh's preflight). This is launch-environment
tooling, not app code - at the D-Bus level it does exactly what Electron's safeStorage does
when it stores a secret.
"""

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

# `--unlock` alone only unlocks a collection that already exists - it can't create one. On a
# machine where no default keyring has ever been created (a fresh box, or right after
# lab/teardown.sh wipes it), the app's first attempt to store a secret would otherwise fall
# through to the normal collection-creation path, which pops an interactive "Choose password
# for NEW keyring" dialog. Creating it here ourselves avoids that dialog entirely.
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
    # The normal creation path always prompts for a password interactively. This legacy method
    # creates a collection with a password we supply (empty) and never shows a dialog -
    # confirmed empirically to work with zero prompts even on a fully fresh machine.
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
            "unlock required a prompt - the collection's password is not empty (was it created "
            "interactively with a real password? clear ~/.local/share/keyrings/ via lab/teardown.sh)"
        )

print("[ensure-keyring] OK -- default collection ready, unlocked, zero prompts", file=sys.stderr)
