# DTL OIDC Lab — Local Zitadel IdP (M2 Step 1)

Per-machine lab infra. **Not committed to git.** Rebuild on each dev box from scratch
(same discipline as `lab/certs/`). The issuer is pinned to `http://127.0.0.1:8080` — it
must match the Electron app's `ISSUER_URL` exactly or token `iss` validation fails (R1).

Admin creds (throwaway local only — not real secrets):
- Username / email: `admin` / `admin@localhost.local`
- Password: `Admin1!`

Loopback callback port the Electron app will use: **`51234`**
(registered as `http://127.0.0.1:51234/callback` in Zitadel — see Manual steps below).

---

## Prerequisites

```bash
# Check podman
podman --version           # needs 4.x+

# Try the compose plugin first (preferred):
podman compose version
# If "command not found", install the Python script:
pip install --user podman-compose
# Then use `podman-compose` instead of `podman compose` in all commands below.
```

---

## BRING UP

```bash
cd ~/Downloads/dtl-app/lab/zitadel

# Pull images first (in case the network is slow):
podman compose pull

# Start in the background:
podman compose up -d
```

**Wait for healthy — Zitadel runs DB migrations on first boot (~30–60 s):**

```bash
# Watch until zitadel logs "server is listening on...":
podman compose logs -f zitadel
# Ctrl-C once you see the listening message.

# Or poll the health endpoint (wait for HTTP 200):
until curl -sf http://127.0.0.1:8080/debug/healthz; do echo "waiting..."; sleep 5; done && echo "UP"
```

**If it doesn't come up:**
```bash
podman compose logs db       # check postgres started OK
podman compose logs zitadel  # look for migration or config errors
# Common causes: port 8080 already in use; subuid issue (try: podman system migrate)
```

---

## MANUAL — Zitadel web UI steps

> These are click-through steps Claude Code cannot perform. Do them once after `BRING UP`.

Open **http://127.0.0.1:8080/ui/console** in the browser on this machine.

**Step 1 — Log in as admin**
- Username: `admin@localhost.local` (try `admin` if that fails)
- Password: `Admin1!`
- If prompted to change password, you can skip or set a new one (update README).

**Step 2 — Create an organisation**
- Top-left menu → **Organizations** → **New organization**
- Name: `DTL-PoC`
- Click **Create** — note the **Org ID** (a UUID shown in the URL or org settings page).

**Step 3 — Create a project**
- Inside DTL-PoC org → **Projects** → **Create project**
- Name: `DTL App`

**Step 4 — Register the native PKCE app**
- Inside DTL App project → **Applications** → **Add application**
- Type: **Native** (not Web, not API)
- Name: `dtl-electron`
- Auth method: **PKCE** — confirm **no client secret** is shown
- Redirect URI: `http://127.0.0.1:51234/callback`
- Post-logout URI: *(leave blank)*
- Click **Save** — copy the **Client ID** shown (save it below).

**Step 5 — Create a test user**
- Top-left → switch to **DTL-PoC** org → **Users** → **New user**
- First name: `Test`, Last name: `User`
- Username: `testuser`
- Email: `testuser@dtl.local` → check **Email verified**
- Set initial password: `Test1234!` → uncheck "force change on next login"
- Click **Create**.

---

## Record these values (needed for M2 Step 2 Electron config)

Fill in after completing the web UI steps above:

```
ISSUER_URL=http://127.0.0.1:8080
CLIENT_ID=<paste from Step 4>
ORG_ID=<paste from Step 2 org settings>
CALLBACK_PORT=51234
TEST_USER_EMAIL=testuser@dtl.local
TEST_USER_PASSWORD=Test1234!
```

---

## VERIFY (lab-first gate — no Electron)

Do NOT start M2 Step 2 (Electron OIDC code) until all three pass.

### (a) Discovery endpoint returns the correct issuer

```bash
curl -s http://127.0.0.1:8080/.well-known/openid-configuration | python3 -m json.tool | grep '"issuer"'
# Expected: "issuer": "http://127.0.0.1:8080"
```

### (b) Zitadel login page loads in the browser

Open **http://127.0.0.1:8080** in the browser — Zitadel UI must render (not a network error).

### (c) Manual auth-code round-trip (proves OIDC flow end-to-end)

Substitute `<CLIENT_ID>` with the value from Step 4, then paste the full URL into the browser:

```
http://127.0.0.1:8080/oauth/v2/authorize?client_id=<CLIENT_ID>&redirect_uri=http%3A%2F%2F127.0.0.1%3A51234%2Fcallback&response_type=code&scope=openid%20profile%20email%20offline_access&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=manual-test-001&nonce=manual-test-nonce-001
```

*(The `code_challenge` above is the RFC 7636 example value — fine for a manual test.)*

1. Zitadel shows the login form → log in as `testuser@dtl.local` / `Test1234!`.
2. The browser tries to redirect to `http://127.0.0.1:51234/callback?code=...&state=manual-test-001`.
3. The page shows **"connection refused"** (nothing is listening on 51234 yet) — this is **expected and correct**.
4. Look at the browser address bar — you must see `?code=<some-code>&state=manual-test-001`.

All three checks pass → the Zitadel lab is ready. Proceed to M2 Step 2.

---

## Tear down / restart

```bash
cd ~/Downloads/dtl-app/lab/zitadel

# Stop (keeps volumes — state survives):
podman compose down

# Nuke everything including the DB (full reset — re-run MANUAL steps after):
podman compose down -v
```

---

## WARNING — per-machine

This Zitadel instance is **local to this machine**. A home box or WSL environment must run
its own instance from scratch (`podman compose up -d`) and redo the MANUAL steps.
The `compose.yml` is committed; the DB data (named volume `zitadel-db`) and any secrets are not.
