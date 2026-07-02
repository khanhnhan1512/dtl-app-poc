// Surfacing only — observability, NOT cryptographic binding. The token is not bound to the
// cert; an extracted token would still work on another device. DPoP/mTLS-bound tokens are
// a post-PoC hardening item (see plans/M4).
export function logSessionIdentity({ deviceCN, userEmail }) {
  console.log(`[session] device=${deviceCN} user=${userEmail}`)
  return { deviceCN, userEmail }
}
