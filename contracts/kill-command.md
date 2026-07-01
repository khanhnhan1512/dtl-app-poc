# Kill-command wire format — language-neutral contract

> Cross-track shared artifact. A verifier in ANY language (Node, Go, Swift, Kotlin) must produce
> the same canonical bytes and pass or fail the same checks. Pin this before any implementation.
> Sources: M3 plan Decision D-M3-6/7 · R1 (canonical-bytes mismatch is the #1 crypto footgun).

---

## 1. JSON field schema

A kill command document is a JSON object with exactly five top-level keys:

| Field        | Type              | Description                                              |
|--------------|-------------------|----------------------------------------------------------|
| `action`     | string            | `"none"` (no-op poll response) or `"wipe"` (execute)    |
| `command_id` | string            | Unique identifier per command (e.g. UUID or `cmd-NNN`). Used by the ledger to prevent re-execution. |
| `device_id`  | string            | Target device. App ignores commands whose `device_id` doesn't match its own identity. |
| `issued_at`  | integer (ms)      | Unix epoch in **milliseconds** (not seconds, not ISO). Freshness window checked by the app. |
| `signature`  | string (base64)   | Ed25519 signature over the canonical payload bytes (see §3). Standard base64 (`+/=` alphabet). |

No other top-level keys are permitted in the signed document.

---

## 2. The canonical signed bytes — EXACT DEFINITION (R1)

This is the critical section. The signature covers a **specific byte sequence**, not the full
document (the `signature` field cannot sign itself). Canonical bytes are constructed as follows:

### Step A — build the payload object

Take the four non-signature fields only:

```
{ "action": <string>, "command_id": <string>, "device_id": <string>, "issued_at": <integer> }
```

### Step B — serialize with keys in ascending lexicographic order, no whitespace

Alphabetical key order: `action` < `command_id` < `device_id` < `issued_at`.

Serialize as **compact JSON** (no spaces around `:` or `,`, no trailing newline):

```
{"action":"wipe","command_id":"cmd-001","device_id":"DTL-Ubuntu-Test-Device","issued_at":1751356800000}
```

Rules:
- String values: standard JSON encoding (escape only what JSON requires).
- Integer value (`issued_at`): no quotes, no decimal point, no exponent — plain integer.
- No extra keys, no extra whitespace, no BOM.

### Step C — encode as UTF-8

The canonical signed bytes = `UTF-8 encode(compact JSON from Step B)`.

### Reference implementation (Node.js)

```js
function canonicalBytes({ action, command_id, device_id, issued_at }) {
  // Key order is alphabetical — matches JSON.stringify with sorted-key serialization.
  const payload = JSON.stringify({ action, command_id, device_id, issued_at })
  return Buffer.from(payload, 'utf8')
}
```

**Cross-language note:** other languages must produce the identical byte string. Verify by
comparing hex dumps against the Node reference before shipping any non-Node verifier.

---

## 3. Signature encoding

- **Algorithm:** Ed25519 (RFC 8032). Pure EdDSA — the algorithm internally hashes; do NOT
  pre-hash the canonical bytes (use `crypto.sign(null, canonicalBytes, privateKey)` in Node,
  `Ed25519.sign(canonicalBytes)` in Go/Java, etc.).
- **Output:** 64 raw bytes.
- **Encoding in JSON:** standard base64 (`+/=`), no line breaks, carried in the `signature` field.

To decode: `Buffer.from(doc.signature, 'base64')` in Node.

---

## 4. Full document example

```json
{
  "action": "wipe",
  "command_id": "cmd-001",
  "device_id": "DTL-Ubuntu-Test-Device",
  "issued_at": 1751356800000,
  "signature": "<base64 of Ed25519 signature over canonical bytes>"
}
```

The JSON document itself may have keys in any order (the verifier extracts fields by name).
Only the canonical bytes (§2) must be in alphabetical key order.

---

## 5. Verification algorithm (numbered steps)

A verifier MUST perform all checks in this order and MUST reject if any fails:

```
1. Parse the document as JSON. Reject if parse fails or any required field is missing.

2. Extract: action, command_id, device_id, issued_at (integer), signature (base64 string).

3. Reconstruct canonical bytes:
   canonical = UTF-8( JSON.stringify({ action, command_id, device_id, issued_at }) )
   — keys in ascending alphabetical order, no whitespace.

4. Decode signature:
   sigBytes = base64_decode(signature)   // 64 bytes; reject if not exactly 64 bytes

5. Verify Ed25519 signature:
   valid = Ed25519.verify(publicKey, canonical, sigBytes)
   If NOT valid → REJECT("bad signature")

6. Check device targeting:
   If device_id != this_device_id → REJECT("not this device")

7. Check freshness:
   now_ms = current time in epoch milliseconds
   If (now_ms - issued_at) > ISSUED_AT_WINDOW_MS → REJECT("stale")
   (ISSUED_AT_WINDOW_MS configurable; recommended default 24 h = 86_400_000 ms)

8. Check single-execution ledger:
   If command_id is in the local executed-commands ledger → REJECT("already executed")

9. Dispatch:
   If action == "wipe" → execute wipe, record command_id in ledger.
   If action == "none" → no-op (log "no command"), record command_id if desired.
   If action is anything else → REJECT("unknown action")
```

**Order matters:** signature check (step 5) MUST precede all semantic checks (6–9) so that
forged or tampered fields are never acted upon, even for logging.

---

## 6. Key management (PoC)

- **Private key:** kept in the lab only (`lab/kill/kill-signing.key`), git-ignored. Plays the role
  of DTL's control-plane signing key. Never shipped in the app.
- **Public key:** hardcoded in the app (`src/main/config.js` → `KILL.publicKeyPem`). The app trusts
  exactly one key. This is `lab/kill/kill-signing.pub` (PEM, `PUBLIC KEY` header, committable).

---

## 7. Device identity convention (PoC)

`device_id` equals the mTLS client-cert Subject CN: **`DTL-Ubuntu-Test-Device`**.
This ties the kill target to the same identity M0 uses for the TLS handshake — consistent across
the PoC. The app reads this from `CERT_SUBJECT_CN` in `src/main/config.js`.
