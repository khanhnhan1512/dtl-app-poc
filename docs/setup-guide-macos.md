# Setup guide (macOS)

This guide is the exact sequence to run the demo on a macOS machine, from installing the application to triggering the kill switch. It is the macOS counterpart to `docs/setup-guide.md`.

One rule before you begin, because it is the single thing that fails silently when ignored: **Always launch the application with `bash lab/run-app-macos.sh`, and never open it from Finder or the Dock.** Launching it any other way skips the per-machine settings this script loads, so the application would sign in against the wrong client identifier and the kill switch would verify commands against the wrong key.

---
## Prerequisites

| Tool | 	How to get it | Purpose |
|---|---|---|
| Postgres.app (a build that includes PostgreSQL 16) | Download from postgresapp.com | The database behind the identity provider. Both the "PostgreSQL 16" and "all currently supported versions" downloads work. Avoid a PostgreSQL 18-only build, which the pinned identity provider version cannot run against |
| Node 20 or newer, with npm | Download from nodejs.org, or install via nvm | Runs the lab's signing scripts |
| Xcode Command Line Tools | `xcode-select --install` | Provides `git`, used to get the repository. Not needed to run the application itself |
| openssl | Preinstalled on macOS | Generates the certificate chain |
| curl | 	Preinstalled on macOS | Checks the lab's endpoints during setup |
| python3 | Preinstalled on macOS | Seeds the test project and user |
| security | 	Preinstalled on macOS | Loads the certificate into the login keychain |
| Apache (httpd) with mod_ssl | 	Preinstalled on macOS | Serves the mTLS test endpoints, in place of the containers used on Linux |

---
## Installing the application

Download the `.dmg` from [the latest release](http://gitlab.intern.dtl/khanhnhan/dtl-app-poc/-/releases).

Open the downloaded file to mount it, drag `DTL App.app` into `/Applications`, then eject the disk image.

```bash
xattr -cr "/Applications/DTL App.app"
```

This clears the mark macOS puts on anything downloaded from the internet. The application is not code-signed, so without this command Gatekeeper blocks it from launching at all.

---
## Cloning the repository

```bash
git clone git@gitlab.intern.dtl:khanhnhan/dtl-app-poc.git
cd dtl-app-poc/
```

> Every command in the rest of this guide assumes you are in this directory.

---
## Setting up the lab

```bash
bash lab/setup-macos.sh
```

This generates the certificate chain, brings up a Postgres database for the identity provider, starts Apache and Zitadel, seeds a test project and a test user, generates the kill switch signing key, and writes the settings specific to this machine.

> Each run starts from a clean state, wiping and rebuilding the lab's own database directory inside this repository. The setup step does not touch anything outside the repository, so it is safe to run on a personal Mac and safe to run repeatedly. Provisioning the certificate later does add an entry to your login keychain, which teardown removes again.

---
## Checking the endpoints (optional)

This separates two different kinds of failure. If these checks fail, the lab itself is broken and the application was never going to work regardless of anything you do next.

```bash
cd lab/certs

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/
# -> 200 (tool-1 accepts this device)

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem https://localhost:8443/
# -> 400 (tool-1 refuses a connection with no client certificate)

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/
# -> 403 (tool-2 refuses this device, by design)

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem https://localhost:8444/
# -> 200 (the kill switch control plane, no client certificate required)

curl -s --cacert ca.pem https://localhost:8444/kill
# -> a signed JSON command. An HTML error page or a connection refused here means the kill switch will not work later

cd ../..
```

---
## Provisioning the certificate

Run these in a real Terminal.app session. They cannot be run over SSH, because macOS refuses keychain interaction from a session with no attached display.

```bash
security import lab/certs/client.p12 -k ~/Library/Keychains/login.keychain-db -P dtltest \
  -T "/Applications/DTL App.app/Contents/MacOS/DTL App"

security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain-db lab/certs/ca.pem
```

The second command `add-trusted-cert` will prompt you for your login password.

---
## Running the application

```bash
bash lab/run-app-macos.sh
```

The script finds the application at `/Applications/DTL App.app` on its own. If you installed it somewhere unusual, point the script at it directly.

```bash
DTL_APP_BIN="/path/to/DTL App.app/Contents/MacOS/DTL App" bash lab/run-app-macos.sh
```

On the first run, your browser opens the login page, where you sign in with the test account created during setup.

```
testuser@dtl.local / Test1234!
```

Once you sign in, the browser shows a short confirmation page and the application opens on its home screen.

---
## Walking through the features

The features behave the same as the Linux build, described in `docs/setup-guide.md`. One thing is different on macOS. A keychain dialog appears the first time the application starts, and again the first time it touches an internal tool. Click **Always Allow** both times. It will not ask again.

---
## Kill switch demo

The application is still running in your first terminal. Open a second Terminal window for this, and change into the repository directory there first, since the command below uses paths relative to it.

```bash
cd dtl-app-poc/
```

Sign a fresh wipe command and place it where the control plane serves it from.

```bash
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" wipe 2>/dev/null > lab/kill/kill-command.json
```

The application polls every 30 seconds, so the command is picked up within half a minute. The terminal shows the verdict, then the wipe itself, then the shutdown:

```
[wipe] Deleted identity "DTL-Ubuntu-Test-Device" from Keychain.
[wipe] Done. { sessionCleared: true, certDeleted: true, tokensCleared: true }
```

<!-- No keychain authorization dialog appears during the wipe itself. The command that removes the identity, `security delete-identity`, is run by `/usr/bin/security`, a binary Apple signs, and that is what the keychain is vouching for when it allows the deletion without asking. The kill switch cannot be defeated on macOS by cancelling a prompt, because there is no prompt to cancel. -->

Launch the application again to see the state a wipe leaves behind. You can still sign in, because the account is untouched, but the device certificate is gone, so the internal tools no longer accept this machine.

### Bringing the machine back

Recovering the device means re-running the certificate import by hand, then telling the control plane to stop serving the wipe command. Run these from the second terminal you opened earlier, still in the repository directory.

```bash
security import lab/certs/client.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P dtltest \
  -T "/Applications/DTL App.app/Contents/MacOS/DTL App"

bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" none 2>/dev/null > lab/kill/kill-command.json
```

Only the import needs to run again, not `add-trusted-cert`, since a wipe leaves the certificate authority trusted. The `none` command is needed because the lab serves a static file, which would otherwise keep offering the spent wipe command. Launch the application and sign in again, and the tools accept the machine as before.

---
## Tear down

```bash
bash lab/teardown-macos.sh
```

This removes everything the lab created, meaning Apache, Zitadel, the Postgres data directory, the stored tokens, the generated certificates, the client identity and trusted CA in the login keychain, and the kill switch signing key. It leaves the prerequisites you installed earlier untouched, including Postgres.app itself. Running `setup-macos.sh` again brings the whole environment back.