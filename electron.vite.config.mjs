import { fileURLToPath } from 'url'
import { dirname, resolve } from 'path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'

const __dirname = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()]
  },
  preload: {
    // M1b — two preloads: index.js (portal, empty) + chrome.js (chrome bar, narrow IPC API).
    plugins: [externalizeDepsPlugin()],
    build: {
      rollupOptions: {
        input: {
          index: resolve(__dirname, 'src/preload/index.js'),
          chrome: resolve(__dirname, 'src/preload/chrome.js')
        }
      }
    }
  },
  renderer: {}
})
