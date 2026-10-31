import { useEffect, useState } from 'react'
type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> }
export function useInstallApp() {
  const [pending, setPending] = useState<InstallEvent | null>(null)
  const [installed, setInstalled] = useState(() => typeof window !== 'undefined' && window.matchMedia('(display-mode: standalone)').matches)
  useEffect(() => {
    const onPrompt = (event: Event) => { event.preventDefault(); setPending(event as InstallEvent) }
    const onInstalled = () => { setInstalled(true); setPending(null) }
    window.addEventListener('beforeinstallprompt', onPrompt)
    window.addEventListener('appinstalled', onInstalled)
    return () => { window.removeEventListener('beforeinstallprompt', onPrompt); window.removeEventListener('appinstalled', onInstalled) }
  }, [])
  const isiOS = typeof navigator !== 'undefined' && /iPhone|iPad|iPod/.test(navigator.userAgent)
  const instructions = isiOS ? 'Use Share → Add to Home Screen in your browser. Then open Chai Khapa from your home screen.' :
    'Install from your browser menu (Install app / Add to Home screen). On supported browsers, use the button below.'
  return { installed, canPrompt: Boolean(pending), instructions, install: async () => { if (pending) { await pending.prompt(); const choice = await pending.userChoice; if (choice.outcome === 'accepted') setPending(null) } } }
}
