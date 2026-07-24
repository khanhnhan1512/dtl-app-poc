# Setup guide (macOS)

This guide is the exact sequence to run the demo on a macOS machine, from installing the application to triggering the kill switch. It is the macOS counterpart to `docs/setup-guide.md`.

One rule before you begin, because it is the single thing that fails silently when ignored: **Always launch the application with `bash lab/run-app-macos.sh`, and never open it from Finder or the Dock.** Launching it any other way skips the per-machine settings this script loads, so the application would sign in against the wrong client identifier and the kill switch would verify commands against the wrong key.

---
## Prerequisites

| Tool | Where it comes from | Purpose |
|---|---|---|
| Postgres.app, with a variant that includes PostgreSQL 16 | postgresapp.com | Runs Zitadel's database. Both the "PostgreSQL 16" download and the "all currently supported versions" download work. Avoid only a PostgreSQL 18-only build, because Zitadel's `34_add_cache_schema` migration fails against PostgreSQL 18, and the Zitadel version this lab is pinned to has no fix for it |
| Node 20 or newer, and npm | nodejs.org or nvm | Required for the lab. `lab/setup-macos.sh` calls two Node scripts directly, one to sign kill commands and one to generate the kill switch's signing keypair, which needs Node's `crypto` module because the LibreSSL macOS ships as `/usr/bin/openssl` cannot generate Ed25519 keys |
| Xcode Command Line Tools | run `git` once and macOS offers to install them, or `xcode-select --install` | Needed for `git`, used in the next section. Not needed for the application itself, since you run the packaged `.app` |
| openssl | ships with macOS | Generating the certificate chain |
| curl | ships with macOS | Waiting for Zitadel to start, and checking endpoints |
| python3 | ships with macOS | Reading Zitadel's setup output while seeding the test project and user |
| security | ships with macOS | Loading the device certificate and trusted CA into the login keychain |
| Apache (httpd) with mod_ssl | ships with macOS | Serves the mTLS test endpoints. This is the macOS substitute for the containers Linux uses, because this hardware cannot run nested virtualization |

---
## Installing the application

<!-- TODO: add the package download link once the .dmg is published to GitLab, the same way
     docs/setup-guide.md's download link was added after the .deb was published (commit c2b561b). -->

Download `DTL App-<version>-universal.dmg`. GitLab requires you to be signed in.

Open the downloaded file to mount it, drag `DTL App.app` into `/Applications`, then eject the disk image.

```bash
xattr -cr "/Applications/DTL App.app"
```

This clears the mark macOS puts on anything downloaded from the internet. The application is not code-signed, so without this command Gatekeeper blocks it from launching at all, even though `lab/run-app-macos.sh` runs it directly rather than through Finder.

---
## Getting the repository

```bash
git clone git@gitlab.intern.dtl:khanhnhan/dtl-app-poc.git
cd dtl-app-poc/
```

Every command in the rest of this guide assumes you are in this directory.

---
## Setting up the lab

```bash
bash lab/setup-macos.sh
```

This generates the certificate chain, brings up a dedicated Postgres data directory for Zitadel, starts Apache and Zitadel, seeds a test project and a test user, generates the signing key for the kill switch, and writes the settings specific to this machine. It stops short of loading the certificate into the login keychain, because that needs a real interactive session and cannot be scripted. It prints the two commands for that at the end, covered in "Provisioning the certificate" below.

> This script starts from a clean state every time it runs, including the Postgres data directory Zitadel uses. Fine on a dedicated test machine, destructive on a personal Mac.

---
## Checking the endpoints (optional)

This separates two different kinds of failure. If these checks fail, the lab itself is broken and the application was never going to work regardless of anything you do next. If these checks pass and the application still misbehaves later, the problem is in the application, not the lab.

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
# -> a signed JSON command. An HTML error page or a connection refused here means the kill switch
#    will not work later

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

Only the second command, `add-trusted-cert`, prompts you for your login password. The first one does not.

`lab/setup-macos.sh` also prints both commands at the end of its run, for anyone working from the script's output instead of this guide.

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

The features behave the same as the Linux build, described in `docs/setup-guide.md`. One thing is different on macOS. A keychain dialog appears the first time the application starts, and again the first time it touches an internal tool. It reads something like "DTL App wants to access the key 'client' in your keychain." This happens because the application is not code-signed, so macOS cannot verify its identity and asks you to vouch for it instead. Click **Always Allow** both times. It will not ask again.

---
## Kill switch demo

With the application running, sign a fresh wipe command and place it where the control plane serves it from.

```bash
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" wipe 2>/dev/null > lab/kill/kill-command.json
```

The application polls every 30 seconds, so the command is picked up within half a minute. The terminal shows the verdict, then the wipe itself, then the shutdown:

```
[wipe] Deleted identity "DTL-Ubuntu-Test-Device" from Keychain.
[wipe] Done. { sessionCleared: true, certDeleted: true, tokensCleared: true }
```

No keychain authorization dialog appears during the wipe itself. The command that removes the identity, `security delete-identity`, is run by `/usr/bin/security`, a binary Apple signs, and that is what the keychain is vouching for when it allows the deletion without asking. The kill switch cannot be defeated on macOS by cancelling a prompt, because there is no prompt to cancel.

Launch the application again to see the state a wipe leaves behind. You can still sign in, because the account is untouched, but the device certificate is gone, so the internal tools no longer accept this machine.

### Bringing the machine back

`lab/reprovision-cert.sh` only knows how to talk to NSS, so it does nothing useful here. Recovering the device means re-running the certificate import by hand, then telling the control plane to stop serving the wipe command.

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

This removes everything the lab created, meaning Apache, Zitadel, the Postgres data directory, the stored tokens, the generated certificates, the client identity and trusted CA in the login keychain, and the kill switch signing key. It leaves the prerequisites you installed earlier untouched, including Postgres.app itself. Unlike setup, teardown runs entirely from a script with no manual step. Running `setup-macos.sh` again brings the whole environment back.