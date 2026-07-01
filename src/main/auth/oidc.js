import { Issuer, generators } from 'openid-client'
import { OIDC } from '../config.js'

/**
 * Discover the IdP and build the authorization URL.
 * Returns everything needed for the exchange step.
 */
export async function startOidcFlow() {
  const issuer = await Issuer.discover(OIDC.issuerUrl)
  console.log('[oidc] Discovered issuer:', issuer.issuer)

  const client = new issuer.Client({
    client_id: OIDC.clientId,
    redirect_uris: [OIDC.redirectUri],
    response_types: ['code'],
    token_endpoint_auth_method: 'none', // native/public PKCE app — no secret
  })

  const codeVerifier = generators.codeVerifier()
  const codeChallenge = generators.codeChallenge(codeVerifier)
  const state = generators.state()
  const nonce = generators.nonce()

  const authUrl = client.authorizationUrl({
    scope: OIDC.scopes,
    state,
    nonce,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
  })

  return { client, authUrl, codeVerifier, state, nonce }
}

/**
 * Exchange the authorization code for tokens.
 * Also fetches userinfo so we can log all available claims.
 * Returns { claims, userinfoClaims, tokenSet }.
 */
export async function exchangeCode(client, code, state, codeVerifier, nonce) {
  // openid-client v5: callback(redirectUri, params, checks)
  // checks.state causes state validation; checks.nonce validates the id_token nonce
  const tokenSet = await client.callback(
    OIDC.redirectUri,
    { code, state },
    { code_verifier: codeVerifier, state, nonce },
  )

  const claims = tokenSet.claims() // id_token JWT claims

  let userinfoClaims = {}
  try {
    userinfoClaims = await client.userinfo(tokenSet.access_token)
  } catch (err) {
    console.warn('[oidc] userinfo fetch failed (non-fatal):', err.message)
  }

  return { tokenSet, claims, userinfoClaims }
}

/**
 * Silent refresh — wraps client.refresh(); caller must persist the returned tokenSet
 * immediately because refresh tokens ROTATE on use.
 */
export async function refresh(client, refreshToken) {
  return client.refresh(refreshToken)
}

/**
 * Company-account gate: email must be verified AND belong to the allowed domain.
 * Prefers userinfo (more authoritative for email claims), falls back to id_token.
 */
export function checkEmailDomain(claims, userinfoClaims = {}) {
  const email = userinfoClaims.email ?? claims.email ?? ''
  const emailVerified = userinfoClaims.email_verified ?? claims.email_verified ?? false
  const suffix = '@' + OIDC.allowedEmailDomain
  const allowed = emailVerified === true && email.endsWith(suffix)
  return { email, emailVerified, allowed }
}
