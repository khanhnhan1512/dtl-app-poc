import { MTLS_ALLOWLIST, CERT_SUBJECT_CN } from './config.js'

export function handleCertSelect(event, _webContents, url, certificateList, callback) {
  event.preventDefault()

  const host = new URL(url).host

  if (!MTLS_ALLOWLIST.includes(host)) {
    console.log(`[cert-select] DECLINED — ${host} not in allowlist`)
    callback()
    return
  }

  const cert = certificateList.find((c) => c.subjectName === CERT_SUBJECT_CN)
  if (cert) {
    console.log(`[cert-select] ALLOWED — ${host} → presenting ${CERT_SUBJECT_CN}`)
    callback(cert)
  } else {
    console.warn(`[cert-select] ALLOWED host ${host} but no cert matching ${CERT_SUBJECT_CN} found`)
    callback()
  }
}
