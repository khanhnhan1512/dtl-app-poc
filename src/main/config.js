const PROTECTED_URL = 'https://localhost:8443'

export const MTLS_ALLOWLIST = ['localhost:8443']
export const CERT_SUBJECT_CN = 'DTL-Ubuntu-Test-Device'
export const TARGET_URL = process.env.DTL_TARGET_URL || PROTECTED_URL
