import { MTLS_ALLOWLIST, CERT_SUBJECT_CN } from './config.js'
import { extractHost } from './allowlist.js'

export function handleCertSelect(event, _webContents, url, certificateList, callback) {
  event.preventDefault()

  console.log('[cert-select] raw url =', JSON.stringify(url))
  const host = extractHost(url)
  console.log('[cert-select] parsed host =', JSON.stringify(host))

  if (!MTLS_ALLOWLIST.includes(host)) {
    console.log(`[cert-select] DECLINED — ${host} not in allowlist`)
    callback()
    return
  }

  const cert = certificateList.find((c) => c.subjectName === CERT_SUBJECT_CN)
  if (cert) {
    console.log(`[cert-select] ALLOWED — ${host} -> presenting ${CERT_SUBJECT_CN}`)
    callback(cert)
  } else {
    console.warn(`[cert-select] ALLOWED host ${host} but no cert matching ${CERT_SUBJECT_CN} found`)
    callback()
  }
}
