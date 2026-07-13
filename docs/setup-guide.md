# Setup guide

How to reproduce the demo on an Ubuntu machine, from a fresh clone to a running app,
including the kill switch. Everything here was verified end to end on a clean VM; the
whole bring-up is two scripts and needs no manual configuration.

One rule up front, because it is the one thing that breaks silently if ignored:

**Always launch the app with `bash lab/run-app.sh`. Never use the desktop menu entry.**
The menu entry does not load the per-machine config (`lab/.runtime-env`), so sign-in
fails against a wrong client ID and the kill switch verifies against a wrong key. The
wrapper exists precisely to inject those values.

## Prerequisites

The setup script checks all of these up front and tells you exactly what is missing. It
never installs anything itself (no sudo assumed). You need:

| What | Ubuntu package / source |
|---|---|
| podman (rootless) | `podman` |
| Node 20+ and npm | nvm recommended |
| openssl, curl | base system |
| certutil and pk12util | `libnss3-tools` |
| python3 | base system |
| python3-dbus | `python3-dbus` (its own package, easy to miss) |
| gnome-keyring, dbus-run-session | `gnome-keyring`, `dbus-x11` |
| xdg-open (opens the OIDC login page) | `xdg-utils` (present on Ubuntu Desktop, easy to miss on a minimal or server install) |

A desktop session is required for the app itself (the GUI and the keyring need a
display). Over NoMachine, run the launch step from the desktop terminal, not an SSH
shell.

## Bring up the lab

```bash
git clone <repo-url>
cd <cloned-directory>   # whatever git named it - no fixed path assumed
bash lab/setup.sh
```

`setup.sh` does the whole thing in one pass: generates the certificate chain, imports
it into NSS, starts nginx (three test endpoints), starts Zitadel with Postgres, creates
the OIDC project, app and test user through the API, generates the kill-switch signing
keypair, and writes the per-machine values to `lab/.runtime-env`. Takes a couple of
minutes on first run (container pulls).

Fair warning: the first line of the script says it and so will we. setup.sh starts from
a clean slate every run. It tears down any existing lab state on the machine, including
the OS login keyring. Fine on a dedicated test box, destructive on your personal
desktop.

When it finishes it prints the curl checks below and the launch command.

## Check the endpoints (optional but quick)

```bash
cd lab/certs
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/ | grep verify=
# -> verify=SUCCESS (tool-1 accepts this device)

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/
# -> 403 (tool-2 refuses this device, by design)

curl -s --cacert ca.pem https://localhost:8444/
# -> verify=NONE (the kill-switch control plane, no client cert required)
cd ../..
```

## Get the app

<!-- TODO: .deb download link - pending release method -->

Download `dtl-app_0.1.0_amd64.deb` and unpack it (no root needed) - substitute the path to
wherever you saved it:

```bash
dpkg -x /path/to/dtl-app_0.1.0_amd64.deb ~/dtl-app-installed
```

Keep `~/dtl-app-installed` as the unpack target: `lab/run-app.sh` auto-detects the packaged
binary there, so no further configuration is needed.

Unpacking with `dpkg -x` instead of installing means the Chromium sandbox helper does
not get its setuid bit; the launch wrapper compensates with
`ELECTRON_DISABLE_SANDBOX=1`. Known trade-off, fine for a lab VM, documented so nobody
mistakes it for a production install method.

## Launch

From the desktop terminal:

```bash
bash lab/run-app.sh
```

`run-app.sh` auto-detects the packaged binary at `~/dtl-app-installed` and launches it -
same command whether you are running the packaged `.deb` or from source. If you unpacked
the `.deb` somewhere else, override the location:

```bash
DTL_APP_BIN="/path/to/dtl-app-installed/opt/DTL App/dtl-app" bash lab/run-app.sh
```

Normal quoting - no escaping needed, the wrapper handles the space internally.

First launch: no keyring dialog of any kind should appear. The system browser opens on
the Zitadel login page. Sign in with:

```
testuser@dtl.local / Test1234!
```

The browser shows a small "login complete" page and the app opens into the home
launcher.

![Sign-in](img/login.png)

## What to check

Walk the tiles in this order; each one demonstrates a different outcome.

**Home.** Six tiles, neutral "Managed device" badge in the top bar, your user and
device identity on the right.

![Home launcher](img/home-launcher.png)

**tool-1: device approved.** The page loads, the badge turns green ("Device verified"),
and the terminal logs one line pairing both identities:

```
[session] device=DTL-Ubuntu-Test-Device user=testuser@dtl.local
```

![Device verified](img/tool1-verified.png)

**The external link inside tool-1.** Click "Open external market data". The app blocks
it locally (amber "Address not permitted" page); the request never leaves the machine
and the badge stays green.

![Address not permitted](img/nav-blocked.png)

**tool-2: device refused.** Same certificate, but this server does not approve this
device: HTTP 403, red badge, "Device blocked". Back returns to the neutral home state.

![Device blocked](img/tool2-blocked.png)

**Warm start.** Quit the app, run the same launch command again. No keyring dialog, no
login: it goes straight to the launcher, reading the encrypted token store.

## Kill switch demo

With the app running, sign a fresh wipe command and put it where the control plane
serves it:

```bash
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" wipe > lab/kill/kill-command.json
```

Within 30 seconds (or immediately on relaunch) the poller picks it up. The terminal
shows the verdict, the wipe, and the app quits:

```
[kill] command_id: cmd-... | action: wipe | verdict: VALID_WIPE
[wipe] Done. { sessionCleared: true, certDeleted: true, tokensCleared: true }
[kill] kill complete - quitting app
```

![Kill switch firing](img/kill-wipe-log.png)

Relaunch to see the locked-out state: the device certificate is gone, so both tools now
refuse the machine, and OIDC asks for a fresh login. This is the intended end state of
a kill.

The command id must be unique (the `$(date +%s)` above handles that): the app keeps a
ledger of executed commands and refuses replays, and it also rejects anything older
than 24 hours or aimed at a different device.

### Restore the machine

```bash
bash lab/reprovision-cert.sh
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" none > lab/kill/kill-command.json
```

Then launch and log in again. Re-provisioning is manual on purpose: a signed command
can take access away, but giving it back requires a human with the provisioning script.

## Tear down

```bash
bash lab/teardown.sh
```

Removes everything the lab created (containers, volumes, certificates, tokens, the
keyring, generated keys) and leaves the prerequisites alone. Running `setup.sh` again
after a teardown brings the whole thing back; the two are designed to cycle.
