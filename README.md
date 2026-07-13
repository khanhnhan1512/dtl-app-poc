# DTL App

A managed browser for DTL's internal tools. Proof of concept, currently Linux only.

The brief was to show we can build a browser we fully control: what it shows, what it
can reach, how it proves which machine and which person is using it, and how we shut it
down remotely when a device is lost or leaves the fleet. All five features below work
today in a packaged .deb, verified end to end on a clean Ubuntu VM.

## Features

### 1. Custom branding

The app ships as "DTL App" with our own name and logo at the OS level: window title,
application menu, package metadata. No Chromium or Electron branding anywhere the user
looks.

### 2. Home launcher

The app opens into a fixed home page listing internal tools as tiles. There is no
address bar, no tabs, no devtools, and no way to navigate anywhere that is not on the
allowlist. Two tiles are live in the lab (tool-1 and tool-2); the rest are placeholders.

![Home launcher](docs/img/home-launcher.png)

### 3. User sign-in (OIDC)

Before the launcher appears, the user signs in through our identity provider (Zitadel
in the lab) in the system browser, using the standard Authorization Code + PKCE flow.
Keeping the login out of the app is deliberate: the app never sees the password, and the
user can check the address bar to confirm they are typing it into the real identity
provider, not into a window we drew.
Only verified accounts on our domain get in. Tokens are stored encrypted through the OS
keyring, so closing and reopening the app does not ask for login again until the token
expires.

![Sign-in](docs/img/login.png)

### 4. Device identity (mTLS)

Each machine holds its own client certificate, and the app presents it only to
allowlisted internal hosts. The server then decides per device. The lab demonstrates
all three outcomes:

- tool-1 approves this device: the page loads and the badge turns green,
  "Device verified".
- tool-2 gets the same certificate but does not approve this device: HTTP 403, red
  badge, "Device blocked".
- A link pointing outside the allowlist never leaves the app at all. It is blocked
  locally with an amber page, and the device identity is untouched.

Every successful tool load also logs which device and which user were behind it, on one
line. That pairing (machine identity from mTLS, person identity from OIDC) is the core
of the model: both must pass independently.

![Device verified](docs/img/tool1-verified.png)
![Device blocked](docs/img/tool2-blocked.png)
![Address not permitted](docs/img/nav-blocked.png)

### 5. Remote kill switch

The app polls a fixed HTTPS endpoint every 30 seconds. The endpoint serves a small JSON
command signed with an Ed25519 key. If the signature verifies, the command names this
device, it is fresh (under 24 hours old) and it has not been executed before, the app
wipes itself: session data, the device certificate and the stored tokens, then quits.
On the next launch there is nothing left to authenticate with. The machine stays locked
out until IT re-provisions it by hand, which is deliberate: a signed command can revoke
access, but granting access back requires a human.

Anything less than a valid signature is logged and ignored. An unreachable endpoint
never triggers a wipe, so a network outage cannot brick the fleet.

![Kill switch firing](docs/img/kill-wipe-log.png)

After a wipe, the machine stays locked out. Even if the user signs in again
through OIDC, the device certificate is gone, so the internal tools refuse the
connection. Access does not come back until IT re-provisions the device by hand.

![Locked out after a wipe](docs/img/kill-locked-out.png)

## What rolling out takes

The short version: Linux needs production plumbing rather than new code, Windows is
incremental work on the same codebase, macOS is the same plus one hurdle we have not
crossed before, and mobile is a separate project.

### Linux

The app is done; the surroundings are not. What the PoC fakes locally, a rollout needs
for real:

- Certificate provisioning. The lab self-signs a throwaway CA and issues the device
  certificate with a script. A rollout needs a real internal CA and a per-machine
  issuing process owned by IT, plus a revocation story on the server side.
- The identity provider. The lab runs Zitadel on the test machine itself. Production
  points the app at a centrally hosted IdP instead; the app only needs its issuer URL
  and client ID, which are already injected at launch rather than baked into the build.
- The kill switch backend. Today the "control plane" is a static signed file on a local
  nginx. A rollout needs a real endpoint IT can push signed commands to, and the
  signing key moves to wherever IT keeps such keys. The command format and the app side
  stay as they are.
- Packaging. The .deb installs and runs, but the PoC launches through a wrapper script
  that injects per-machine config, and the lab install skips the Chromium sandbox
  (documented, fine for a VM, not for real desktops). A rollout wants proper installs
  with config delivered by whatever manages our Linux machines.

None of this touches the five features. It is deployment work, and most of it (CA, IdP,
kill backend) is shared groundwork that Windows and macOS then reuse.

### Windows

The known path. Everything in the Linux list above applies here too; what follows is
the Windows-specific part.

The app code itself is portable: Electron builds Windows binaries from the same source,
and electron-builder already produces .exe installers with a config change. The real
work is certificate provisioning. Linux uses the NSS database; Windows uses the OS
certificate store, which Electron reads natively, so the in-app code stays as is and
the provisioning scripts change from certutil to PowerShell. Token encryption actually
gets simpler: safeStorage uses DPAPI on Windows out of the box, so the whole keyring
bootstrap we needed on Linux disappears. The lab scripts are bash and would need
PowerShell equivalents. We already have Windows VMs, so this can be tested as soon as
it is built.

### macOS

Mostly known, one real unknown.

Portability and certificate handling mirror Windows: packaging becomes .dmg,
certificates go to the macOS Keychain (imported via the security CLI), and both the
client cert lookup and safeStorage use Keychain with no extra bootstrap. The unknown is
distribution. Modern macOS refuses to run unsigned apps, so shipping even an internal
.dmg means an Apple Developer account, code signing certificates and Apple's
notarization step. We have not done this before. Treat any macOS estimate as soft until
we have run notarization once. We would also need a macOS machine for building and
testing, which is a sysadmin request.

### iOS and Android

Not a port. Electron does not run on mobile, so this is a second codebase, native or
something like React Native, sharing specifications rather than code.

What transfers: the kill-command format is deliberately language neutral, so a mobile
client verifies the same Ed25519 signature over the same bytes. The OIDC flow is
standard AppAuth territory on both platforms. The allowlist and badge concepts carry
over as product design.

What does not: all the Electron and JavaScript code. And client-certificate handling
inside iOS's WKWebView is possible but far more constrained than desktop Chromium. We
would want a small spike there before promising anything; it is the single hardest item
on the mobile list.

## Seeing it run

Everything needed to reproduce the demo on a fresh Ubuntu machine is in
[docs/setup-guide.md](docs/setup-guide.md). One script stands up the whole lab
(certificates, the mTLS endpoints, the identity provider with a seeded test user), and
one script launches the app. No manual configuration.

### Download

<!-- TODO: .deb download link - pending release method -->
The packaged build is `dtl-app_0.1.0_amd64.deb`. Download location: to be added once we
settle on the release channel.
