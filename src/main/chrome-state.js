// Chrome bar state - the small state object Main pushes to chromeView.
// Kept separate from window.js (one concern per file, matching navigation.js/allowlist.js).
import { TOOLS, CERT_SUBJECT_CN } from './config.js'
import { extractHost } from './allowlist.js'
import {
  CHROME_STATE_CHANNEL,
  CHROME_GO_HOME_CHANNEL,
  CHROME_READY_CHANNEL
} from '../shared/chrome-ipc.js'

export { CHROME_STATE_CHANNEL, CHROME_GO_HOME_CHANNEL, CHROME_READY_CHANNEL }

// host -> tool label, derived from TOOLS (skips tool-3…6, whose URL is null).
const TOOL_HOSTS = Object.fromEntries(
  Object.entries(TOOLS)
    .filter(([, url]) => url)
    .map(([label, url]) => [extractHost(url), label])
)

export function toolLabelForUrl(url) {
  return TOOL_HOSTS[extractHost(url)] ?? null
}

// kind: 'home' | 'tool-ok' | 'tool-blocked'. Any other kind returns null - callers must not
// push a state for a URL that matched no branch (e.g. the local address-not-permitted page),
// which is what leaves the previously pushed state (green) standing.
export function buildState(kind, { label, userEmail } = {}) {
  const identity = { deviceCN: CERT_SUBJECT_CN, userEmail }
  switch (kind) {
    case 'home':
      return { title: 'DTL App', subtitle: 'Managed workspace', badge: 'neutral', showBack: false, ...identity }
    case 'tool-ok':
      return { title: label, subtitle: 'dtl internal service', badge: 'green', showBack: true, ...identity }
    case 'tool-blocked':
      return { title: label, subtitle: 'dtl internal service', badge: 'red', showBack: true, ...identity }
    default:
      return null
  }
}

export function sendChromeState(chromeView, state) {
  if (!state) return
  chromeView.webContents.send(CHROME_STATE_CHANNEL, state)
}
