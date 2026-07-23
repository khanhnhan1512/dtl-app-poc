# Setup guide (macOS)

This guide reproduces the demo on a macOS machine, starting from a fresh clone and ending with a running application, including the kill switch. It is the macOS counterpart to `docs/setup-guide.md`, but nothing here is carried over from that guide without being checked again on a real Mac. Where the two platforms genuinely differ, this guide says so explicitly rather than leaving it implied.

One rule before you begin, because it is the single thing that fails silently when ignored: **Always launch the application with `bash lab/run-app-macos.sh`, and never open it from Finder or the Dock.** Launching it any other way skips the per-machine settings this script loads, so the application would sign in against the wrong client identifier and the kill switch would verify commands against the wrong key.

---
## Prerequisites

| Tool | Where it comes from | Purpose |
|---|---|---|
| Postgres.app, with a variant that includes PostgreSQL 16 | postgresapp.com | Runs Zitadel's database. Both the "PostgreSQL 16" download and the "all currently supported versions" download include a PostgreSQL 16 binary and work fine. Avoid only a PostgreSQL 18-only build, because Zitadel's `34_add_cache_schema` migration fails against PostgreSQL 18, and the Zitadel version this lab is pinned to has no fix for it |
| Node 20 or newer, and npm | nodejs.org or nvm | Required for the lab, not optional. `lab/setup-macos.sh` calls two Node scripts directly, one to sign kill commands and one to generate the kill switch's signing keypair. The keypair generator specifically needs Node's `crypto` module, because the LibreSSL build macOS ships as `/usr/bin/openssl` cannot generate Ed25519 keys. You do not need a build toolchain (Xcode Command Line Tools or similar) for this, because you run the packaged `.app` rather than building from source |
| openssl | ships with macOS | Generating the certificate chain, meaning the CA, the server certificate, and the device certificate |
| curl | ships with macOS | Waiting for Zitadel to finish starting, and checking the test server's endpoints |
| python3 | ships with macOS | Reading Zitadel's setup output while seeding the test project, app, and user |
| security | ships with macOS | Loading the device certificate into the login keychain, and trusting the lab's certificate authority |
| Apache (httpd) with mod_ssl | ships with macOS | Serves the mTLS test endpoints. This is the macOS substitute for the containers Linux uses, because this hardware cannot run nested virtualization and podman is not an option here |

---
## Setting up the environment

```bash
git clone git@gitlab.intern.dtl:khanhnhan/dtl-app-poc.git
cd dtl-app-poc/
bash lab/setup-macos.sh
```

The `lab/setup-macos.sh` script does everything a native process can do on its own. It generates the certificate chain, starts Apache and Zitadel, seeds a test project and a test user, generates the signing key for the kill switch, and writes the settings that are specific to this machine. It stops short of loading the certificate into the login keychain, because that step needs a real interactive session and cannot be scripted. The script tells you exactly what to run for that at the end, and the next two sections of this guide walk through it.

> This script starts from a clean state every time it runs. It removes any lab state already on the machine, including the Postgres data directory Zitadel uses. This is fine on a dedicated test machine and destructive on a personal Mac.

---
## Check the endpoints (optional)

This section is worth running even though it is optional, because it separates two different kinds of failure. If these checks fail, the lab itself is broken and the application was never going to work regardless of anything you do next. If these checks pass and the application still misbehaves later, the problem is in the application, not the lab. That distinction matters more here than on Linux, because the Apache configuration behind these ports is newer and less proven than the container setup Linux uses.

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
# -> a signed JSON command. This is the check most worth running, because a silent failure here
#    (an HTML error page, or a connection refused) means the kill switch will not work later, and
#    nothing about the application's own behavior will tell you that in advance

cd ../..   # back to the repo root
```

---
## Installing the application

Install the `.dmg` before you provision the certificate, not after. The command that loads the certificate into the keychain uses a flag, `-T`, that grants a specific application permission to use the key without a password prompt every time. That flag needs the application to already exist at the path it is pointed at, so installing first is not just tidier, the later command fails outright if you skip ahead.

Download `DTL App-<version>-universal.dmg` and open it. GitLab requires you to be signed in to download it.

Because the `.dmg` is not signed, Gatekeeper blocks it the first time you try to open a copy that macOS knows was downloaded from the internet. Right-click the `.app` inside the mounted `.dmg`, choose **Open**, and confirm in the dialog that appears. This one-time step is macOS asking you to vouch for an application it cannot verify on its own, not a sign that anything is actually wrong with it.

```bash
xattr -cr "/Applications/DTL App.app"
```

If the right-click approach does not work for some reason, this command clears the quarantine attribute directly and has the same effect. Drag the application into `/Applications` first if you have not already.

---
## Provisioning the certificate

These two commands need a real Terminal.app session. They cannot be run over SSH, because macOS refuses keychain interaction from a session with no attached display.

```bash
security import "/path/to/dtl-app-poc/lab/certs/client.p12" \
  -k ~/Library/Keychains/login.keychain-db \
  -P dtltest \
  -T "/Applications/DTL App.app/Contents/MacOS/DTL App"

security add-trusted-cert -r trustRoot -p ssl \
  -k ~/Library/Keychains/login.keychain-db \
  "/path/to/dtl-app-poc/lab/certs/ca.pem"
```

Only the second command, `add-trusted-cert`, prompts you for your login password. The first one does not.

`lab/setup-macos.sh` prints both commands with the paths already filled in for your machine, so copy them from its output rather than retyping the two above.

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

The features themselves behave the same as the Linux build, described in `docs/setup-guide.md`. Two things are different on macOS and worth knowing about before you see them.

**A keychain dialog appears the first time the application touches each internal tool.** It reads something like "DTL App wants to access the key 'client' in your keychain." This happens because the application is not code-signed, so macOS cannot verify its identity on its own and asks you to vouch for it instead, the same underlying reason the Gatekeeper prompt appeared during installation. Click **Always Allow**. It appears once per destination, meaning once for tool-1 and once for tool-2, and does not come back after that.

**The console log carries two kinds of harmless noise.** Errors from Chromium's GPU process appear on every launch, because this machine has no GPU to pass through to the application. You will also see repeated `task_policy_set TASK_SUPPRESSION_POLICY: invalid argument` messages. Neither indicates a real problem. They are expected on this hardware and safe to ignore.

---
## Kill switch demo

With the application running, sign a fresh wipe command and place it where the control plane serves it from.

```bash
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" wipe 2>/dev/null > lab/kill/kill-command.json
```

The application polls every 30 seconds, so the command is picked up within half a minute. The terminal shows the verdict, then the wipe itself, then the shutdown. The line confirming the certificate was removed differs from the Linux build, because macOS uses the keychain rather than NSS:

```
[wipe] Deleted identity "DTL-Ubuntu-Test-Device" from Keychain.
[wipe] Done. { sessionCleared: true, certDeleted: true, tokensCleared: true }
```

No keychain authorization dialog appears during the wipe itself. The command that removes the identity, `security delete-identity`, is run by `/usr/bin/security`, a binary Apple signs, and that is what the keychain is actually vouching for when it allows the deletion without asking. This means the kill switch cannot be defeated on macOS by cancelling a prompt, because there is no prompt to cancel.

Launch the application again to see the state a wipe leaves behind. You can still sign in, because the account is untouched, but the device certificate is gone, so the internal tools no longer accept this machine. That is the intended end state.

### Bringing the machine back

Recovery is different on macOS than on Linux. `lab/reprovision-cert.sh` only knows how to talk to NSS, so it does nothing useful here. Recovering the device means re-running the certificate import by hand, then telling the control plane to stop serving the wipe command.

```bash
security import "/path/to/dtl-app-poc/lab/certs/client.p12" \
  -k ~/Library/Keychains/login.keychain-db \
  -P dtltest \
  -T "/Applications/DTL App.app/Contents/MacOS/DTL App"

bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" none 2>/dev/null > lab/kill/kill-command.json
```

Only the import needs to run again, not the trust command. A wipe removes the device identity but leaves the certificate authority trusted, so `add-trusted-cert` was never undone and running it a second time would be redundant, not wrong. Launch the application and sign in again, and the tools accept the machine as before.

Recovery is manual by design, the same as on Linux. Revoking a machine can be done remotely, but restoring it requires someone with access to the certificate.

---
## Tear down

```bash
bash lab/teardown-macos.sh
```

This removes everything the lab created, meaning Apache, Zitadel, the Postgres data directory, the stored tokens, the generated certificates, the client identity and trusted CA in the login keychain, and the kill switch signing key. It leaves the prerequisites you installed earlier untouched, including Postgres.app itself, so the machine is back to the state it was in before you started.

Unlike setup, teardown runs entirely from a script with no manual step. Removing a keychain identity and removing a trusted certificate both turn out not to need an interactive session, even though adding them in the first place does. Running `setup-macos.sh` again brings the whole environment back, and the two scripts are designed to be run in that cycle as often as you like.
