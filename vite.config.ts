import { defineConfig } from 'vite'
import type { Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Vite SPA fallback may serve /index.html when browsing /privacy/ locally.
// Rewrite clean URLs to the standalone HTML files under public/.
function legalPageRoutes(): Plugin {
  const resolveLegalRoute = (requestUrl?: string) => {
    const [path, query] = (requestUrl ?? '').split('?', 2)
    const target = path === '/privacy' || path === '/privacy/'
      ? '/privacy/index.html'
      : path === '/terms' || path === '/terms/'
        ? '/terms/index.html'
        : null
    return target ? target + (query ? '?' + query : '') : null
  }
  return {
    name: 'chai-khapa-standalone-legal-pages',
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        req.url = resolveLegalRoute(req.url) ?? req.url
        next()
      })
    },
    configurePreviewServer(server) {
      server.middlewares.use((req, _res, next) => {
        req.url = resolveLegalRoute(req.url) ?? req.url
        next()
      })
    },
  }
}

export default defineConfig({
  plugins: [legalPageRoutes(), react(), tailwindcss()],
  server: { port: 5173 },
})
