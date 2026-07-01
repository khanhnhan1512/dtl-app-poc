# DTL Kill-Switch Lab — Ed25519 signing infra (M3 Step 1)

Per-machine lab infra. **Not committed (private key).** Same discipline as `lab/certs/` and
`lab/zitadel/`. The private key plays the role of DTL's control-plane signing key.
Wire format pinned in `contracts/kill-command.md`.

---

## Files

| File                  | Committed? | Purpose                                              |
|-----------------------|-----------|------------------------------------------------------|
| `gen-keypair.sh`      | Yes        | Generate a fresh Ed25519 keypair on this machine     |
| `sign-command.sh`     | Yes        | Sign a kill command per the contract                 |
| `verify-check.js`     | Yes        | Standalone Node verifier — M3 Step 1 gate check      |
| `kill-signing.key`    | **NO**     | Ed25519 private signing key (git-ignored)            |
| `kill-signing.pub`    | Yes        | Ed25519 public key (hardcoded in the app later)      |
| `kill-wipe.json`      | Yes        | Signed sample: `action:"wipe"`                       |
| `kill-none.json`      | Yes        | Signed sample: `action:"none"` (no-op)               |

---

## Device identity

`device_id` = **`DTL-Ubuntu-Test-Device`** — matches the mTLS client-cert Subject CN from M0.
Consistent across the PoC: the same identity string appears in the TLS handshake and the kill target.

---

## BRING UP (if keypair is missing — e.g. fresh clone)

```bash
cd lab/kill
bash gen-keypair.sh
# Then re-sign the sample commands:
bash sign-command.sh DTL-Ubuntu-Test-Device cmd-001 wipe  2>/dev/null > kill-wipe.json
bash sign-command.sh DTL-Ubuntu-Test-Device cmd-002 none  2>/dev/null > kill-none.json
```

After regenerating the keypair, update `KILL.publicKeyPem` in `src/main/config.js` (Step 3).

---

## VERIFY — M3 Step 1 hand-verification gate (no Electron needed)

```bash
cd ~/Downloads/dtl-app

# Both should print VALID:
node lab/kill/verify-check.js lab/kill/kill-wipe.json
node lab/kill/verify-check.js lab/kill/kill-none.json

# Tamper test — should print INVALID:
node -e "
  const d = JSON.parse(require('fs').readFileSync('lab/kill/kill-wipe.json','utf8'))
  d.action = 'none'   // flip the action
  require('fs').writeFileSync('/tmp/tampered.json', JSON.stringify(d,null,2))
"
node lab/kill/verify-check.js /tmp/tampered.json   # → INVALID — bad signature
```

All three pass → Step 1 is verified. Proceed to Step 2 (serve via nginx `:8444`).

---

## SIGN A NEW COMMAND

```bash
# Wipe command:
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-<N> wipe 2>/dev/null > lab/kill/kill-wipe.json

# No-op (poll placeholder):
bash lab/kill/sign-command.sh DTL-Ubuntu-Test-Device cmd-<N> none 2>/dev/null > lab/kill/kill-none.json
```

`issued_at` defaults to now (epoch ms). Pass a 4th argument to override.
