# M3 — Remote kill switch: signed command + poll + reuse of `wipe()`

> Detailed plan for **Milestone M3** of `plans/roadmap.md`. **Planning only — no code yet.**
> Per the CLAUDE.md two-tier gate, this plan is reviewed and approved *before* any code is written.
> Sources: roadmap M3 · brainstorm **F1–F4** (kill switch + wipe) · techstack (Ed25519 verify in Main,
> Node built-in crypto) · `plans/M2-oidc.md` (the now token-aware `wipe()` and its
> `{ sessionCleared, certDeleted, tokensCleared }` result) · `plans/M0-spike.md` (nginx lab, NSS certs).
> Builds on **approved + verified M0 + M1 + M2** code in `src/main/` (cert handler, `wipe()`,
> `createShell()`, auth gate).

## Goal

Prove that the organization can **remotely disable a managed device**: a mock control plane publishes a
**signed kill command**, the app **polls** for it, **verifies the Ed25519 signature** in the main
process, and — only for a valid, fresh, device-targeted command — invokes the existing token-aware
`wipe()`. M3 demonstrates the *trust* path (the app obeys only genuinely-signed commands from DTL), not
a production control plane. Recovery stays **manual** (`lab/reprovision-cert.sh` + re-login), exactly as
in M2 — **kill is one-way in the PoC**.

M3 reuses `wipe()` unchanged; it adds a *trigger* in front of it. That is the whole point of having kept
`wipe()` UI-agnostic and reusable since M0.

## Acceptance criteria (from roadmap M3)

1. The app **polls** the mock control plane for a kill command — **at launch and periodically** while
   running (interval configurable).
2. The kill command is **cryptographically signed (Ed25519)**; the app **verifies** it against a
   **hardcoded public key** and **ignores** anything that fails verification.
3. A **valid, fresh, device-targeted** kill command triggers `wipe()` (session + NSS cert + tokens) —
   the same full-scope wipe verified in M2.
4. A **tampered, unsigned, replayed, stale, or wrong-device** command is **ignored** (logged, no wipe).
5. After a kill-triggered wipe, the device is locked out of **both** layers (no token ⇒ re-login forced;
   no cert ⇒ `:8443` returns nginx 400) — identical end state to the manual `--wipe`. Recovery is manual.

## How M3 composes with M0/M1/M2 (the explicit "do they interact?" answer)

- **M3 is a trigger in front of `wipe()`.** It does **not** touch the cert handler, the OIDC flow, the
  token store, or the kiosk shell. It adds `src/main/kill/` (poller + verifier) and one call site:
  `wipe()` (already token-aware from M2). The kill path asserts the same
  `{ sessionCleared, certDeleted, tokensCleared }` result object M2 produced.
- **Independent of the auth gate.** The kill check runs on its own timer, decoupled from
  `ensureAuthenticated()`. A kill can fire whether or not the user is currently authenticated — a
  killed device must lock out regardless of session state. (Sequencing detail resolved in Decisions.)
- **Reuses the M0 nginx lab as the "control plane."** No new runtime server: the mock backend is a
  **static signed JSON file** served by the existing podman nginx (a new `location`), so there is no
  Node/Express process, no new port, no new systemd/podman surface. `curl` verifies the server side
  before the app touches it (same discipline as M0's `verify=SUCCESS`).
- **Wipe/recover asymmetry is preserved.** Kill only ever **wipes** (destroys access). Re-provisioning
  a cert (granting new access) requires a deeper trust anchor and stays the manual `reprovision-cert.sh`
  path — **not** a signed command. Folding recover into the signed-command path would blur that
  boundary and is explicitly out of scope (see Decisions).

## Acceptance-critical design: what makes a signed *file* a real kill switch

A naive "signed JSON file" is not yet a kill switch — it is a static signature. Three properties turn it
into one, and all three are **inside the signed payload** (so tampering breaks the signature):

- **Device targeting (`device_id`)** — the command names *which* device it kills. The app ignores a
  command whose `device_id` isn't its own. Prevents one leaked command wiping every device.
- **Freshness (`issued_at`)** — a timestamp; the app rejects commands older than a configurable window
  *for replay defense at rest*. (See the replay note below — freshness alone is not enough.)
- **Single-execution (`command_id` + local ledger)** — a unique id per command; the app records
  executed command ids and **never re-executes** the same one. Prevents a re-served or re-observed
  command from wiping a freshly-recovered device again.

**Replay/staleness note (honest limitation).** With a *static* file there is no server-side nonce
challenge, so the app cannot fully prevent an attacker who can serve an old-but-not-yet-stale file. The
PoC mitigations are: (a) `command_id` ledger stops re-execution on the *same* device; (b) `issued_at`
window bounds how long a captured command stays valid; (c) `device_id` scopes blast radius. A true
anti-replay (server nonce / mutual challenge) is a documented post-PoC hardening item. This is the
"static backend" trade-off you accepted — recorded, not hidden.

## Prerequisites & key gotchas

- **Verification env (carried from M0–M2):** GUI runs on the **Ubuntu desktop VM** (`duccanh-test-pc.dtl`)
  via NoMachine; code built/pushed from dshell. Because a kill triggers `wipe()` which clears tokens,
  and re-testing needs a fresh login, **the safeStorage/keyring `dbus-run-session` wrapper from M2
  Decision 8 applies to every VM launch that authenticates**. (Kill verification itself needs no
  keyring, but the surrounding login/wipe cycle does.)
- **Ed25519 = Node built-in `crypto` — NO new dependency.** Node's `crypto.verify(null, msg, publicKey,
  signature)` supports Ed25519 natively. Keep `openid-client` as the *only* runtime dep (Decision 2
  discipline). Do **not** add `tweetnacl`/`libsodium`.
- **Keys are lab infra, per-machine — never committed.** The **private** signing key lives only in the
  lab (git-ignored, like the certs), playing the role of DTL's control plane. The **public** key is
  hardcoded/shipped in the app (the app trusts DTL's key). Same per-machine discipline as `lab/certs/*`.
- **nginx caches / static files:** after changing the signed JSON, the app sees it on the next poll; no
  nginx restart needed for a static file swap (unlike cert changes). `curl` the file to confirm.
- **Canonical bytes for signing.** The signature must cover an **exact byte sequence**, not a re-parsed
  object (JSON key order / whitespace can change bytes and break verification). The contract must define
  *what exact bytes are signed* — sign a canonical serialization (or sign a detached string and ship it
  verbatim). This is the #1 crypto-integration footgun; the contract spec pins it.

## Architecture (M3 shape)

New `src/main/kill/` module group; one new call site into existing `wipe()`.

```
app.whenReady()
  ├─ ensureAuthenticated()            ← M2, unchanged
  ├─ createShell()                    ← M1/M2, unchanged
  └─ startKillPoller()                ← NEW
        ├─ checkKillOnce()            ← runs at launch, then every interval
        │    ├─ fetch(KILL_URL)               (static JSON via M0 nginx)
        │    ├─ verifyKillCommand(json)        ← Ed25519 verify + device_id + issued_at + command_id
        │    │     └─ (invalid/stale/not-me/already-done) → log + ignore
        │    └─ (valid, fresh, for-me, unseen) → recordExecuted(command_id) → wipe() → quit/lock
        └─ setInterval(checkKillOnce, KILL.pollIntervalMs)
```

- **`contracts/kill-command.md`** *(new — language-neutral spec)* — the wire format: JSON field schema
  (`device_id`, `issued_at`, `command_id`, `action`), the exact canonical bytes that are signed, the
  Ed25519 signature encoding (base64), and the verification algorithm. This is the true cross-track
  shared artifact (a future iOS/Android build verifies the *same* format with different code).
- **`src/main/kill/verify.js`** *(new)* — pure logic: given the fetched JSON + the hardcoded public key,
  verify signature (Node `crypto`), check `device_id` == this device, `issued_at` within window,
  `command_id` not in the executed ledger. Returns a verdict enum. No Electron deps → unit-testable.
- **`src/main/kill/poller.js`** *(new)* — `fetch` the URL, hand the body to `verify.js`, and on a valid
  verdict call `wipe()` then lock/quit. Owns the interval timer and the launch check.
- **`src/main/kill/ledger.js`** *(new — small)* — persist executed `command_id`s (a plain file in
  `userData`; not secret, just an idempotency record). Survives restarts so a re-served command isn't
  re-run after recovery.
- **`src/main/config.js`** *(modify)* — add `KILL` block: `url`, `pollIntervalMs`, `deviceId`,
  `issuedAtWindowMs`, and the hardcoded `publicKeyPem` (or a constant module). Env-overridable
  (`DTL_KILL_*`), per-machine.
- **`src/main/index.js`** *(modify)* — call `startKillPoller()` after `createShell()`; keep `--wipe`,
  `--login`, cert handler, menu gate exactly as-is.
- **`src/main/wipe.js`** — **unchanged**; M3 only calls it. (If a future partition is added, the M1/M2
  caveat still applies — noted, not changed.)
- **Lab:** `lab/kill/` — Ed25519 keypair (git-ignored private key), a `sign-command.sh` (signs a JSON
  payload with the lab private key), and the nginx `location` serving the signed file. Mirrors the
  `lab/certs` + `lab/zitadel` per-machine pattern.

## Sub-steps (ordered: prove crypto outside Electron → serve statically → verify in app → wire wipe → poll)

> Mirrors M0/M2 discipline: prove the new infra **outside Electron first**, retire the highest-
> uncertainty integration (signature verification) before wiring the destructive action, then layer
> polling last. Each step is independently verifiable on the VM before the next. **The wipe wiring
> (Step 4) is the regression gate — a kill must leave the exact M2 `--wipe` end state.**

### Step 1 — Contract + Ed25519 keypair + signing, proven by hand (retires the crypto risk)

- **Files:** `contracts/kill-command.md` *(new spec)*; `lab/kill/` — keypair gen, `sign-command.sh`,
  sample `kill-command.json` (both an `action:"none"` no-op and an `action:"wipe"` command, each signed).
- **What it does:** defines the wire format + canonical signing bytes; generates the lab Ed25519 keypair
  (private stays in lab, git-ignored); signs sample payloads.
- **Verify (VM, no Electron):** a standalone Node script (`lab/kill/verify-check.js`) loads the public
  key and **verifies the signed sample by hand** → prints VALID; then flip one byte in the JSON →
  prints INVALID. Proves the canonical-bytes + Ed25519 round-trip *before* any app code. (Same spirit as
  M0's by-hand `curl`/`openssl` and M2's by-hand `?code=` round-trip.)

### Step 2 — Serve the signed command via the M0 nginx lab

- **Files:** `lab/kill/` nginx `location` (added to the existing M0 nginx config); README run notes.
- **What it does:** the existing podman nginx serves `kill-command.json` at a fixed URL (e.g.
  `https://localhost:8443/kill` or the non-mTLS `:8444` — see the open question in Decisions).
- **Verify (VM):** `curl` the URL → returns the signed JSON; swap the file (no-op ↔ wipe) → `curl`
  reflects the change. Server side proven before the app polls (M0 discipline).

### Step 3 — Verify in Main (no wipe yet — retires the in-app verification risk)

- **Files:** `src/main/kill/verify.js` *(new)*, `src/main/kill/ledger.js` *(new)*,
  `src/main/config.js` *(modify — KILL block + hardcoded public key)*.
- **What it does:** fetch + verify (signature, `device_id`, `issued_at`, `command_id`), returning a
  verdict. **Does NOT call wipe** — logs the verdict only (`WOULD WIPE` / `IGNORED: bad signature` /
  `IGNORED: not this device` / `IGNORED: stale` / `IGNORED: already executed` / `no command`).
- **Verify (VM):** point the app at the served file; run once. With the valid `wipe` command → logs
  `WOULD WIPE`. Tamper the file → `IGNORED: bad signature`. Wrong `device_id` → `IGNORED: not this
  device`. Old `issued_at` → `IGNORED: stale`. This retires the verification logic before anything
  destructive is wired.

### Step 4 — Wire the valid verdict to `wipe()` (REGRESSION GATE — kill == manual --wipe end state)

- **Files:** `src/main/kill/poller.js` *(new — the check + wipe call)*, `src/main/index.js`
  *(modify — call it once at launch for this step)*.
- **What it does:** a valid/fresh/for-me/unseen command → `recordExecuted(command_id)` → `wipe()` →
  lock/quit. First real destructive path.
- **Verify (VM — regression gate):** authenticate (tokens.enc present) + cert present; serve the valid
  `wipe` command; launch → app fetches, verifies, wipes. Confirm the **exact M2 `--wipe` end state**:
  `[wipe] SUCCESS { sessionCleared: true, certDeleted: true, tokensCleared: true }`; `tokens.enc` gone;
  `certutil -L` shows the device cert gone; relaunch → forced re-login AND `:8443` → nginx 400. Then
  confirm idempotency: re-serving the *same* `command_id` after recovery → `IGNORED: already executed`
  (no second wipe). Recovery via `reprovision-cert.sh` + re-login restores `verify=SUCCESS`.

### Step 5 — Poll at launch + periodically (the full kill-switch behaviour)

- **Files:** `src/main/kill/poller.js` *(extend — interval timer)*, `src/main/index.js` *(modify —
  `startKillPoller()` after `createShell()`)*.
- **What it does:** checks at launch, then every `pollIntervalMs`. Demonstrates "admin flips the switch
  mid-session": start with the no-op command served, app runs normally; you (as admin) swap in the
  signed `wipe` command; on the next poll the app wipes and locks. Handles the unreachable-backend case
  per the fail-open/closed decision.
- **Verify (VM):** launch with no-op served → app runs, portal loads, periodic `no command` / `IGNORED`
  logs. Swap to the signed `wipe` file → within one interval the app wipes + locks (same end state as
  Step 4). Stop nginx (unreachable) → app behaves per the chosen fail policy (open: keeps running;
  closed: per variant). 

## Decisions (resolved before implementation)

1. **Delivery — app polls a static signed JSON (D-M3-1/3).** No push, no long-poll, no runtime server.
   Served by the existing M0 nginx as a static file. Simplest infra; sufficient to prove the trust path.
2. **Timing — check at launch + on a configurable interval (D-M3-2).** `pollIntervalMs` short for demo
   (e.g. 30–60 s), env-overridable.
3. **Crypto — Ed25519 via Node built-in `crypto`; NO new dependency.** Hand-rolling is not at issue
   (standard primitive, standard API); adding a crypto lib is unnecessary.
4. **Keys — Ed25519 public key hardcoded in the app; private key lab-only, git-ignored (D-M3-4).** App
   trusts DTL's key; the lab plays the control plane. Per-machine, like the certs.
5. **Scope — kill only WIPES; recovery stays manual (D-M3-5).** One-way in the PoC. Folding recover into
   the signed path is rejected (wipe/recover asymmetry — different trust anchors; recover needs
   provisioning, out of PoC scope: no MDM, no remote cert re-provisioning).
6. **Anti-replay — `device_id` + `issued_at` window + `command_id` ledger inside the signed payload
   (D-M3-6).** Full server-nonce anti-replay is a documented post-PoC item (static-backend trade-off).
7. **Contract — wire format is a language-neutral spec in `contracts/kill-command.md` (D-M3-7).** The
   true cross-track shared artifact; pins the canonical signed bytes.
8. **Fail policy — FAIL-OPEN (D-M3-8, resolved).** When the control plane is unreachable, the app does
   nothing and keeps running. Rationale: a destructive, one-way action fires only on a *positive,
   authenticated* signal — never on the *absence* of one; network blips are common and harmless, so
   wipe-on-blip would be a catastrophic false-positive. Documented limitation: a thief who keeps the
   device offline evades the kill; heartbeat + grace-period lockout is a post-PoC hardening item.
   *(Considered and rejected: fail-closed-as-wipe — couples destruction to a frequent benign condition;
   fail-closed-as-temporary-lockout — non-destructive but adds a last-seen/grace state machine that
   enlarges M3 beyond proving the kill switch.)*
9. **Kill endpoint — `:8444` non-mTLS (D-M3-9, resolved).** The control channel is independent of the
   device-cert lifecycle. Serving on `:8443` would require the client cert to poll — which is *gone
   after a wipe* — creating a chicken-and-egg. Since kill is one-way (no un-kill), a killed device still
   being able to poll is harmless.
10. **Post-kill behaviour — `app.quit()` (D-M3-10, resolved).** After wipe the app quits; the locked-out
    state is surfaced on the next relaunch via the existing M2 auth gate (no token ⇒ forced re-login)
    and M0 mTLS (no cert ⇒ `:8443` nginx 400). No separate "device disabled" screen is built.

## Risk assessment

- **R1 (highest) — canonical-bytes mismatch** between signer (lab) and verifier (app) ⇒ valid commands
  fail verification. *Mitigation:* Step 1 proves the round-trip by hand with a standalone verifier
  *before* app code; the contract pins the exact signed bytes.
- **R2 — verification bug lets an invalid command through** ⇒ unauthorized wipe. *Mitigation:* Step 3
  tests all reject paths (tamper, wrong device, stale) with wipe **not yet wired**; only Step 4 connects
  the destructive call.
- **R3 — kill wiring regresses M0/M1/M2** (breaks the shell, cert handler, or auth). *Mitigation:* M3
  adds a module + one call site; `wipe.js` unchanged; Step 4 asserts the exact M2 `--wipe` end state.
- **R4 — replay/re-execution** wipes a recovered device again. *Mitigation:* `command_id` ledger
  (idempotent), tested in Step 4; `issued_at` window.
- **R5 — fail policy wrong** ⇒ either wipe-on-blip (too aggressive) or evade-by-offline (too weak).
  *Mitigation:* O-1 decided explicitly at review; default fail-open with the limitation documented.
- **R6 — private key leaks into the repo.** *Mitigation:* git-ignore `lab/kill/*.key` from Step 1;
  only the public key is committed/shipped.

## Security considerations (PoC scope)

- **Signature verified in Main only** (like all M2 auth logic); the renderer never sees the command or
  the verification.
- **Only the public key ships in the app; the private key never leaves the lab.** App trusts exactly one
  key.
- **Signed payload binds device + freshness + single-use** (`device_id`, `issued_at`, `command_id`);
  tampering any field breaks the signature.
- **Kill reuses the M2 full-scope `wipe()`** (session + cert + tokens) — no separate, weaker teardown.
- **One-way:** kill only destroys; recovery needs the manual provisioning path (deeper trust anchor).
- **Out of scope (documented):** server-nonce anti-replay; MDM; remote cert re-provisioning /
  "un-kill"; heartbeat/grace-period lockout (unless O-1 → B); DLP.

## Definition of Done (mirrors roadmap M3)

- [ ] **DoD-1** — App polls the control plane at launch + periodically (interval configurable).
- [ ] **DoD-2** — Kill command is Ed25519-signed; app verifies against the hardcoded public key.
- [ ] **DoD-3** — Valid/fresh/for-this-device/unseen command ⇒ `wipe()` (session + cert + tokens),
  same result object as M2.
- [ ] **DoD-4** — Tampered / unsigned / wrong-device / stale / already-executed ⇒ ignored (logged, no
  wipe). All reject paths demonstrated.
- [ ] **DoD-5** — Post-kill end state == manual `--wipe`: forced re-login + `:8443` nginx 400; recovery
  via `reprovision-cert.sh` + re-login. Kill is one-way.
- [ ] **DoD-6 (regression)** — M0 mTLS, M1 shell, M2 auth all intact; `wipe.js` unchanged; kill is a
  trigger in front of the existing wipe.
- [ ] **DoD-7** — Wire format documented in `contracts/kill-command.md` (canonical signed bytes pinned);
  no new runtime dependency (Ed25519 via Node `crypto`).
- [ ] Fail policy is fail-open (D-M3-8); kill endpoint is `:8444` non-mTLS (D-M3-9); post-kill the app
  quits (D-M3-10).

## Next steps (after approval)

- Implement Steps 1 → 5 in order, verifying each on the VM before proceeding (Step 1 gates Step 2;
  Step 4 is the regression gate).
- On M3 sign-off, write the detailed **M4 (device-bound mTLS ↔ OIDC session integration + OS packaging)**
  plan — one milestone at a time.