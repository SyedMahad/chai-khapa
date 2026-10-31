import { useEffect, useState } from 'react'
import type { User } from '@supabase/supabase-js'
import { hasSupabaseConfig, supabase } from './lib/supabase'

type Stage = 'checking' | 'ready' | 'error'

function App() {
  const [user, setUser] = useState<User | null>(null)
  const [stage, setStage] = useState<Stage>(hasSupabaseConfig ? 'checking' : 'ready')
  const [error, setError] = useState('')

  useEffect(() => {
    if (!supabase) return
    const client = supabase
    let mounted = true
    client.auth.getUser().then(({ data, error: authError }) => {
      if (!mounted) return
      setUser(data.user)
      setStage('ready')
      if (authError && authError.name !== 'AuthSessionMissingError') setError(authError.message)
    }).catch((reason: unknown) => {
      if (!mounted) return
      setStage('error')
      setError(reason instanceof Error ? reason.message : 'Could not connect to authentication.')
    })
    const { data: { subscription } } = client.auth.onAuthStateChange((_event, session) => {
      if (mounted) { setUser(session?.user ?? null); setStage('ready') }
    })
    return () => { mounted = false; subscription.unsubscribe() }
  }, [])

  async function signIn() {
    if (!supabase) return
    setError('')
    const { error: authError } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: window.location.origin + '/' },
    })
    if (authError) setError(authError.message)
  }

  async function signOut() {
    if (!supabase) return
    const { error: authError } = await supabase.auth.signOut()
    if (authError) setError(authError.message)
  }

  const nickname = user?.user_metadata?.full_name ?? user?.email ?? 'Colleague'
  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand"><span className="brand-icon" aria-hidden="true">☕</span> Chai Khapa</div>
        <span className="tag">Infrastructure preview</span>
      </header>
      <main className="main">
        <div className="eyebrow">CHAI KHAPA · STEP 2</div>
        <h1>Chai together.<br /><em>Settle later.</em></h1>
        <p className="lead">A simpler way for colleagues to track shared chai bills — without splitting every Rs. 70 on the spot.</p>
        <section className="panel" aria-label="Setup status">
          <div className="panel-heading">Environment & authentication</div>
          {!hasSupabaseConfig ? (
            <div className="notice">Setup required: add <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_PUBLISHABLE_KEY</code>. Follow <code>SETUP.md</code>.</div>
          ) : stage === 'checking' ? (
            <p className="muted">Checking your sign-in session…</p>
          ) : user ? (
            <>
              <div className="status success">✓ Google account authenticated</div>
              <h2>Welcome, {nickname}</h2>
              <p className="muted">Your identity is connected. Groups, expenses, and notifications arrive in Step 3 and Step 4.</p>
              <button className="secondary" onClick={signOut}>Sign out</button>
            </>
          ) : (
            <>
              <div className="status">Supabase client configured</div>
              <p className="muted">Google Sign-In needs the OAuth provider and redirect URLs configured in Supabase and Google Cloud.</p>
              <button onClick={signIn}>Continue with Google</button>
            </>
          )}
          {stage === 'error' || error ? <p className="error" role="alert">{error}</p> : null}
        </section>
        <section className="next-step">
          <span className="dot"/> Ready for the next milestone: database schema, group-level security, and first expense entry.
        </section>
      </main>
      <footer>Chai Khapa · PKR · Asia/Karachi</footer>
    </div>
  )
}
export default App
