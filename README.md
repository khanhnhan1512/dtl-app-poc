# DTL App (Proof of Concept)

DTL App replaces standard browsers to provide a secure, locked-down gateway for accessing DTL's internal tools. Designed to enforce strict access management and corporate data protection, it requires concurrent validation of both the physical device and the authenticated employee, while integrating a remote kill-switch to immediately wipe local corporate credentials if the device is compromised.

The main goal of this project was to show we can build a browser we fully control.

## Features

### 1. Custom Branding & Home Launcher

The application is fully customized as "DTL App" across the window title and system menus. It opens directly into a locked home page that restricts navigation strictly to approved corporate tools. Currently, two active tools (`tool-1` and `tool-2`) are functional for lab testing, while the rest serve as placeholders.

![Home launcher](docs/img/home-launcher.png)

### 2. Custom Authentication (OIDC)

The application locks access until the user logs in through our identity provider `Zitadel` (configured for the test environment). The login flow opens in the system browser using the standard OIDC protocol and only allows accounts from the corporate domain (`@dtl.local`). 

For testing purposes, a default account has been pre-created:
* **Username:** `testuser@dtl.local`
* **Password:** `Test1234!`

Once logged in, the tokens are encrypted and stored directly inside the operating system's keyring. This keeps the session active so users do not need to log in again every time the app restarts.

![Sign-in](docs/img/login.png)
### 3. Device Identity (mTLS)

To demonstrate our capability to fully customize client-side verification, the application enforces a unique cryptographic identity for every machine. Each machine is provisioned with a distinct client certificate bound to a specific expiration date, allowing the infrastructure to identify and verify the exact client machine.

Crucially, the certificate resides within the OS certificate store rather than inside the application bundle. This ensures that reinstalling the app preserves the machine's identity, while copying the application binary to another device will not clone its access rights.

In the lab, the certificate is issued by a self-signed CA through a provisioning script and loaded into the machine's NSS store. Provisioning is deliberately separate from installing the app so the app never generates its own identity, it only presents one that was granted to the machine.

The browser presents this unique certificate exclusively to allowlisted internal hosts, which evaluate access permissions on a per-device basis. The lab environment demonstrates three operational outcomes:

* **Approved Device (tool-1):** The server validates the certificate, the page loads successfully, and the badge turns green `Device verified`.

  ![Device verified](docs/img/tool1-verified.png)

* **Blocked Device (tool-2):** The server detects the certificate but explicitly denies this specific device instance, returning an HTTP 403 error and a red badge `Device blocked`.

  ![Device blocked](docs/img/tool2-blocked.png)

* **Unlisted Navigation:** Any link pointing outside the corporate allowlist is blocked locally via an amber warning page. The request never leaves the machine, ensuring the device identity is never exposed.

  ![Address not permitted](docs/img/nav-blocked.png)

---

**Technical note (PoC Scope):** Device certificates in the lab are issued with an 825-day lifespan, but we have not built anything to handle one lapsing. An expired certificate fails at the TLS handshake, before any HTTP response exists, so it never reaches the access-denied page that a refused (403) or missing (400) certificate goes through. It lands instead in the app's load-failure path, which today only logs to the console: the user would see a blank view with the badge unchanged and no explanation. Production needs a renewal policy and a proper message on that failure path.

### 4. Remote Kill Switch

To demonstrate remote revocation without an Mobile Device Management (MDM), the application polls a fixed HTTPS control-plane endpoint every 30 seconds. In the lab, this endpoint is served by the local nginx instance at `https://localhost:8444/kill`, which returns a small JSON command signed with an Ed25519 key.

The app executes a wipe only when every check passes: the signature must verify against the trusted public key, the command must name this specific device, it must be fresh (issued within the last 24 hours), and it must not have been executed before. A ledger of executed command IDs prevents an old command from being replayed.

Once a valid wipe command is received, the app destroys its own access: session data, the device certificate, and the encrypted tokens. It then quits. The demonstration produces two observable outcomes:

* **Execution:** The terminal logs the verdict, the wipe result, and the shutdown. There is nothing left on the machine to authenticate with.

  ![Kill switch firing](docs/img/kill-wipe-log.png)

* **Lockout:** On the next launch, the user can still sign in through OIDC, but the device certificate is gone. The internal tools reject the machine, and access only returns once the certificate is re-provisioned manually. The asymmetry here is deliberate. Revoking access is remote and instant while restoring it is not. A signed command can lock a machine out from anywhere, but bringing it back requires someone to re-provision the certificate on that machine.

  ![Locked out after a wipe](docs/img/kill-locked-out.png)

The switch also fails safe, in both directions. A command that does not verify is logged and ignored rather than acted on. And if the endpoint cannot be reached, the app does nothing and keeps running.

## Path to production

### Linux

The application itself is finished. What is not finished is everything around it, because the lab fakes those parts locally. A real rollout needs each of them for real:

* **Issuing certificates to machines.** The lab uses a throwaway CA and a manual script to provision device certificates. A production rollout requires a real internal CA and a defined lifecycle strategy: establishing who provisions new machines, when it occurs, and how certificates are revoked for lost devices or offboarded employees. This is a company-wide operational framework rather than application code.

* **Enforcing mTLS on internal services.** Our internal services do not request a client certificate today, so the lab stands up an nginx server that does. A real rollout requires configuring each internal web application to trust our CA and handle device-level authorization. This configuration takes place on the infrastructure side rather than inside the browser app, scaling with the number of integrated applications.

* **Moving to a central identity provider.** The lab runs its own login server on the test machine. In production the application would point at whatever identity provider the company already uses. The application only needs the address of that provider and an identifier for itself, and both of those are already supplied at launch rather than compiled into the build, so this is a configuration change rather than a code change.

* **Building a real control plane for the kill switch.** Today the kill command is a static signed file served by the local nginx. A rollout needs a real service that someone can push a signed command to, and the signing key needs to live wherever the company keeps keys of that kind. The command format and the application side of it stay exactly as they are.

* **Packaging and installation.** The package installs and runs, but the PoC launches through a wrapper script that supplies the per-machine settings, and the lab installation skips the Chromium sandbox, which is acceptable on a test machine and not acceptable on a real desktop. A rollout wants a normal installation, with settings delivered by whatever manages our Linux machines.

### Windows

This is the known path. Everything in the Linux list above still applies, and what follows is only what is specific to Windows.

The application code is portable, because Electron builds Windows binaries from the same source and our packaging tool already produces Windows installers with a configuration change. The real work is again in certificates. Linux stores them in a database called NSS, while Windows stores them in its own certificate store, which Electron reads natively, so the code inside the application stays as it is and only the provisioning scripts change from Linux tooling to PowerShell. Token storage actually gets easier, because Windows encrypts them through its own built-in mechanism, so the keyring setup we needed on Linux disappears entirely. The lab scripts are written in bash and would need PowerShell equivalents. We already have Windows machines available, so this can be tested as soon as it is built.

### macOS

Mostly known, with one real unknown.

Portability and certificate handling look much like Windows. Packaging becomes a disk image, certificates go into the macOS Keychain, and both the certificate lookup and the token storage use that same Keychain with no extra setup. The unknown is distribution. Modern macOS refuses to run applications that Apple has not approved, so shipping even an internal build means an Apple developer account, signing certificates, and Apple's notarization step. We have not done this before, so any estimate for macOS should be treated as soft until we have been through notarization once. We would also need a macOS machine to build and test on, which is a request for the systems team.

### iOS and Android

Mobile is not a port. Electron does not run on phones, so this would be a second codebase, either native or something like React Native, and it would share specifications with the desktop application rather than share code.

Some things carry across. The kill command format was designed to be independent of any programming language, so a mobile client can verify the same signature over the same bytes. The login flow is standard on both platforms and there are well-established libraries for it. The allowlist and the badge that tells the user whether their device is trusted carry across as product design rather than as code.

Other things do not carry across at all, starting with every line of the Electron and JavaScript code. More importantly, handling client certificates inside the web view that iOS forces applications to use is possible but far more constrained than it is on desktop. We would want a small experiment there before promising anything, because it is the hardest single item on the mobile list.

## Seeing it run

Everything needed to reproduce the demo on a fresh Ubuntu machine is in
[docs/setup-guide.md](docs/setup-guide.md). One script stands up the whole lab
(certificates, the mTLS endpoints, the identity provider with a seeded test user), and
one script launches the app. No manual configuration.

### Download

<!-- TODO: .deb download link - pending release method -->
The packaged build is `dtl-app_0.1.0_amd64.deb`. Download location: to be added once we
settle on the release channel.
