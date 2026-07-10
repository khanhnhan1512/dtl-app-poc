import http from 'http'
import { URL } from 'url'

// Port MUST match the redirect_uri registered in Zitadel.
const LOOPBACK_PORT = 51234
const LOOPBACK_HOST = '127.0.0.1' // explicit IPv4 - 'localhost' may resolve to ::1

const SUCCESS_HTML =
  '<html><body style="font-family:sans-serif;padding:2em">' +
  '<h2>Login complete - you can close this tab.</h2>' +
  '</body></html>'

/**
 * Start an HTTP listener on 127.0.0.1:51234 and wait for the OIDC callback.
 * Resolves with { code, state } once the redirect arrives.
 * Times out after 5 minutes (user abandoned the browser).
 * expectedState is used to reject spoofed callbacks early.
 */
export function startLoopbackServer(expectedState) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let url
      try {
        url = new URL(req.url, `http://${LOOPBACK_HOST}:${LOOPBACK_PORT}`)
      } catch {
        res.writeHead(400).end()
        return
      }

      if (url.pathname !== '/callback') {
        res.writeHead(404).end()
        return
      }

      const error = url.searchParams.get('error')
      if (error) {
        const desc = url.searchParams.get('error_description') || ''
        res.writeHead(400, { 'Content-Type': 'text/html' })
        res.end(`<html><body><h2>Login error: ${error}</h2><p>${desc}</p></body></html>`)
        server.close()
        clearTimeout(timer)
        reject(new Error(`OAuth error: ${error} - ${desc}`))
        return
      }

      const code = url.searchParams.get('code')
      const state = url.searchParams.get('state')

      if (!code || state !== expectedState) {
        res.writeHead(400, { 'Content-Type': 'text/html' })
        res.end('<html><body><h2>Invalid callback (bad state or missing code)</h2></body></html>')
        server.close()
        clearTimeout(timer)
        reject(new Error(`Invalid loopback callback: state=${state} code=${!!code}`))
        return
      }

      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(SUCCESS_HTML)
      server.close()
      clearTimeout(timer)
      resolve({ code, state })
    })

    const timer = setTimeout(() => {
      server.close()
      reject(new Error('Loopback timeout - no callback received within 5 minutes'))
    }, 5 * 60 * 1000)

    server.on('error', (err) => {
      clearTimeout(timer)
      reject(err)
    })

    server.listen(LOOPBACK_PORT, LOOPBACK_HOST)
  })
}
