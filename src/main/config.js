const PROTECTED_URL = 'https://localhost:8443'

export const PRODUCT_NAME = 'DTL App'
export const MTLS_ALLOWLIST = ['localhost:8443']
export const NAV_ALLOWLIST = (process.env.DTL_NAV_ALLOWLIST || 'localhost:8443').split(',')
export const CERT_SUBJECT_CN = 'DTL-Ubuntu-Test-Device'
export const HOME_URL = process.env.DTL_TARGET_URL || PROTECTED_URL
