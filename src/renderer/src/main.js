import logoUrl from '../assets/logo.png'

document.getElementById('logo').src = logoUrl

const ICONS = {
  neutral: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="1"/><path d="M8 20h8M12 16v4"/></svg>',
  green: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
  red: '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.2-2.4M3 3l18 18"/></svg>'
}

const LABELS = { neutral: 'Managed device', green: 'Device verified', red: 'Device blocked' }

const badge = document.getElementById('badge')
const badgeIcon = document.getElementById('badge-icon')
const badgeLabel = document.getElementById('badge-label')
const backBtn = document.getElementById('back-btn')
const titleEl = document.getElementById('chrome-title')
const subtitleEl = document.getElementById('chrome-subtitle')
const avatar = document.getElementById('avatar')
const identityEmail = document.getElementById('identity-email')
const identityCN = document.getElementById('identity-cn')

function applyState(state) {
  titleEl.textContent = state.title
  subtitleEl.textContent = state.subtitle
  badge.className = `pill ${state.badge}`
  badgeIcon.innerHTML = ICONS[state.badge] ?? ICONS.neutral
  badgeLabel.textContent = LABELS[state.badge] ?? LABELS.neutral
  backBtn.classList.toggle('visible', Boolean(state.showBack))

  if (state.userEmail) {
    identityEmail.textContent = state.userEmail
    avatar.textContent = state.userEmail.slice(0, 2).toUpperCase()
  }
  if (state.deviceCN) {
    identityCN.textContent = state.deviceCN
  }
}

backBtn.addEventListener('click', () => window.dtlChrome.goHome())
window.dtlChrome.onState(applyState)
// Registered AFTER onState - guarantees Main's re-push (triggered by this ready ping) arrives
// after the listener above is in place, closing the initial-state race.
window.dtlChrome.ready()
