# Setup guide

This guide reproduces the demo on an Ubuntu machine, starting from a fresh clone and ending with a running application, including the kill switch. Everything described here was verified end to end on a clean machine. The whole process comes down to two scripts and requires no manual configuration.

One rule before you begin, because it is the single thing that fails silently when ignored: **Always launch the application with `bash lab/run-app.sh` command, and never open it from the desktop menu.** The menu entry does not load the per-machine settings, so the application would sign in against the wrong client identifier and the kill switch would verify commands against the wrong key. The launch script exists precisely to supply those values.

---
## Prerequisites

| Tool | Package | Purpose |
|---|---|---|
| podman, running rootless | `podman` | Runs the containers for the test server and the identity provider |
| Node 20 or newer, and npm | nvm is the easiest route | Signing kill commands, and building from source if you want to |
| openssl | `openssl` | Generating the certificate chain, meaning the CA, the server certificate, and the device certificate |
| curl | `curl` | Waiting for the identity provider to finish starting, and checking the test server's endpoints |
| certutil and pk12util | `libnss3-tools` | Loading the device certificate into the machine's certificate store |
| python3 | `python3` | Running the kill switch signing script, and reading the identity provider's setup output |
| python3-dbus | `python3-dbus` | Preparing the keyring so the app never shows a password prompt. This is its own package and is easy to miss |
| gnome-keyring and dbus-run-session | `gnome-keyring` and `dbus-x11` | Encrypting the login tokens through the operating system |
| xdg-open | `xdg-utils` | Opening the login page in your browser. |

---
## Setting up the environment

```bash
git clone git@gitlab.intern.dtl:khanhnhan/dtl-app-poc.git
cd dtl-app-poc/
bash lab/setup.sh
```

The `lab/setup.sh` script does everything. It generates the certificate chain, loads the device certificate into the machine's certificate store, starts the internal test server, brings up the identity provider with a project and a test user already created, generates the signing key for the kill switch, and writes the settings that are specific to this machine. The first run takes a few minutes because it downloads the container images.

> This script starts from a clean state every time it runs. It removes any lab state already on the machine, including the operating system login keyring. This is fine on a dedicated test machine and destructive on a personal desktop.

---
## Check the endpoints (optional)

```bash
cd lab/certs

curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/ | grep verify=
# -> verify=SUCCESS (tool-1 accepts this device)

curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/
# -> 403 (tool-2 refuses this device, by design)

curl -s --cacert ca.pem https://localhost:8444/
# -> verify=NONE (the kill switch control plane, no client certificate required)

curl -s --cacert ca.pem https://localhost:8444/kill
# -> a signed JSON command. If you see an HTML error page instead, the kill switch will not work

cd ../..   # back to the repo root
```

---
## Installing the application


Download `dtl-app_0.1.0_amd64.deb` and unpack it. This needs no administrator rights, and it is how the demo was verified.

Get the file from the [package download page](http://gitlab.intern.dtl/khanhnhan/dtl-app-poc/-/packages/1). GitLab requires you to be signed in to download it.

```bash
dpkg -x /path/to/dtl-app_0.1.0_amd64.deb ~/dtl-app-installed
```

Keep `~/dtl-app-installed` as the destination, because the launch script looks for the application there and needs no further configuration.

> Unpacking without root does not give the Chromium sandbox helper the permissions it needs, so the launch script disables the sandbox in order to start. The sandbox is a real isolation layer and a production install would keep it. This is an accepted trade-off for a demo on a dedicated test machine, and it is not how the application should be deployed for real.

---
## Running the application

Run this from the desktop terminal.

```bash
bash lab/run-app.sh
```

The script finds the application on its own, whether you unpacked the package or installed it with administrator rights. If you put it somewhere unusual, you can point the script at it.

```bash
DTL_APP_BIN="/path/to/dtl-app-installed/opt/DTL App/dtl-app" bash lab/run-app.sh
```

On the first run, your browser opens the login page, where you sign in with the test account created during setup.

```
testuser@dtl.local / Test1234!
```
![Sign-in](img/login.png)

Once you sign in, the browser shows a short confirmation page and the application opens on its home screen.

---
## Walking through the features


**The home screen.** Six tiles, a neutral `Managed device` badge in the top bar, and your account and device identity on the right.

![Home launcher](img/home-launcher.png)

**tool-1.** The page loads and the badge turns green `Device verified`. At the same time, the terminal logs a single line that pairs the machine identity with the signed in account.

```
[session] device=DTL-Ubuntu-Test-Device user=testuser@dtl.local
```

![Device verified](img/tool1-verified.png)

**The external link inside tool-1.** Click `Open external market data`. The application blocks it locally and shows a warning page. The request never leaves the machine, and the badge stays green, because this is an address restriction rather than a device problem.

![Address not permitted](img/nav-blocked.png)

**tool-2.** The application presents the same certificate, but this server does not approve this particular device, so it returns an HTTP 403 and the badge turns red `Device blocked`.

![Device blocked](img/tool2-blocked.png)

**Restarting the application.** Quit and launch it again. No password prompt appears and you are not asked to log in, because the application reads the encrypted tokens it stored during the first sign in.

---
## Kill switch demo

With the application running, sign a fresh wipe command and place it where the control plane serves it from.

```bash
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" wipe 2>/dev/null > lab/kill/kill-command.json
```

The application polls every 30 seconds, so the command is picked up within half a minute. The terminal then shows the verdict, the wipe itself, and the shutdown:

![Kill switch firing](img/kill-wipe-log.png)

Launch the application again to see the state a wipe leaves behind. You can still sign in, because the account is untouched, but the device certificate is gone, so the internal tools no longer accept this machine. That is the intended end state.

Note that each command needs its own identifier, which is what `$(date +%s)` provides above. The application keeps a record of the commands it has already carried out and refuses to run the same one twice. It also ignores anything issued more than 24 hours ago, or aimed at a different machine.

### Bringing the machine back

```bash
bash lab/reprovision-cert.sh
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device "cmd-$(date +%s)" none 2>/dev/null > lab/kill/kill-command.json
```

The first command issues the machine a new certificate. The second replaces the wipe command with a harmless one, so the control plane is no longer serving an instruction to wipe. Launch the application and sign in again, and the tools accept the machine as before.

Recovery is manual by design. Revoking a machine can be done remotely, but restoring it requires someone with access to the provisioning script.

---
## Tear down

```bash
bash lab/teardown.sh
```

This removes everything the lab created, meaning the containers, the certificates, the stored tokens, the login keyring, and the generated keys. It leaves the prerequisites you installed earlier untouched, so the machine is back to the state it was in before you started. Running `setup.sh` again brings the whole environment back, and the two scripts are designed to be run in that cycle as often as you like.
