const PROTECTED_URL = 'https://localhost:8443'

export const PRODUCT_NAME = 'DTL App'
export const MTLS_ALLOWLIST = ['localhost:8443']
export const NAV_ALLOWLIST = (process.env.DTL_NAV_ALLOWLIST || 'localhost:8443').split(',')
export const CERT_SUBJECT_CN = 'DTL-Ubuntu-Test-Device'
export const HOME_URL = process.env.DTL_TARGET_URL || PROTECTED_URL

// Kill switch — M3. All values are env-overridable (DTL_KILL_*).
// publicKeyPem: the Ed25519 public key the app trusts exactly one signing key from.
// Source: lab/kill/kill-signing.pub (per-machine lab key — NOT a production key).
// To update: re-run lab/kill/gen-keypair.sh, paste the new PEM here, re-sign all kill commands.
export const KILL = {
  url:              process.env.DTL_KILL_URL              || 'https://localhost:8444/kill',
  caPath:           process.env.DTL_KILL_CA_PATH          || 'lab/certs/ca.pem',
  deviceId:         process.env.DTL_KILL_DEVICE_ID        || CERT_SUBJECT_CN,
  issuedAtWindowMs: Number(process.env.DTL_KILL_WINDOW_MS || 86_400_000),
  pollIntervalMs:   Number(process.env.DTL_KILL_INTERVAL_MS || 30_000),
  publicKeyPem: process.env.DTL_KILL_PUBLIC_KEY_PEM || `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEASBCOmaNomk/87Sp40h6aqm/6sqC4426Vkkzr2gFzHDM=
-----END PUBLIC KEY-----
`,
}

// OIDC — M2. All values are env-overridable (DTL_OIDC_*).
export const OIDC = {
  issuerUrl:   process.env.DTL_OIDC_ISSUER              || 'http://127.0.0.1:8090',
  clientId:    process.env.DTL_OIDC_CLIENT_ID           || '379679934110564995',
  redirectUri: process.env.DTL_OIDC_REDIRECT            || 'http://127.0.0.1:51234/callback',
  scopes:      'openid profile email offline_access',
  // PoC company-account gate: email_verified + email domain (Decision 6 "email-domain is the prod
  // path"). Org scoping is enforced at Zitadel (the client lives in the DTL org); this is the
  // Main-process defense-in-depth check. No special Zitadel scope required.
  allowedEmailDomain: process.env.DTL_OIDC_ALLOWED_EMAIL_DOMAIN || 'dtl.local',
}
