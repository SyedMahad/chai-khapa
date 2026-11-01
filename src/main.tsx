import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './chai-khapa.css'
import './phase35.css'
import './phase36.css'
import './phase37.css'
import './phase38-finance.css'
import './phase39-recovery.css'
import './phase40-contributors.css'
import './chai-select.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)

// Install service worker only on production/preview builds, not Vite's HMR dev server.
if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => { void navigator.serviceWorker.register('/sw.js').catch(console.warn) })
}
