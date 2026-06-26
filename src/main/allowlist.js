export function extractHost(u) {
  try {
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(u)) return new URL(u).host
    return new URL(`https://${u}`).host
  } catch { return '' }
}

export function isAllowed(url, list) {
  return list.includes(extractHost(url))
}
