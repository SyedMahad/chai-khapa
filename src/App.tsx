import { useEffect, useState } from 'react'
import type { User } from '@supabase/supabase-js'
import { hasSupabaseConfig, supabase } from './lib/supabase'

type Stage = 'checking' | 'ready' | 'error'

export default function App() {
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
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="topbar">
        <a className="brand" href="/" aria-label="Chai Khapa home"><span className="monogram">CK<span>.</span></span><span>CHAI KHAPA</span></a>
        <nav className="nav" aria-label="Primary navigation"><a href="#how-it-works">How it works</a><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a></nav>
      </header>
      <main id="main" className="main">
        <section className="hero" aria-labelledby="hero-heading">
          <div className="eyebrow">SMALL BILLS <span>/</span> ZERO AWKWARDNESS</div>
          <h1 id="hero-heading">Good chai.<br/><em>Clear hisaab.</em></h1>
          <p className="lead">One person pays at the dhaba. Everyone settles their share later. Chai Khapa keeps track of the details, so your group doesn't have to.</p>
          <div className="hero-rule"><span>BUILT FOR THE EVERYDAY CHAI BREAK</span><span className="decorative-star" aria-hidden="true">✳</span></div>
        </section>
        <section className="sign-panel" aria-label="Sign in">
          <div className="sign-heading"><span className="label">01 / THE ACCOUNT</span><span className="available">EARLY ACCESS</span></div>
          {user ? <><p className="sign-title">Welcome back.</p><p className="muted">Signed in as <strong>{nickname}</strong>. The group and expense features are the next milestone.</p><button className="secondary" onClick={signOut}>Sign out</button></>
          : <><h2 className="sign-title">Your seat at the table.</h2><p className="muted">Sign in to get started. The first recording features are on the way.</p>
            {!hasSupabaseConfig ? <p className="notice">Setup required: add your public Supabase environment variables to the deployment.</p>
              : stage === 'checking' ? <p className="muted">Checking your session…</p>
              : <button className="primary" onClick={signIn}>Continue with Google <span aria-hidden="true">↗</span></button>}</>}
          {stage === 'error' || error ? <p className="error" role="alert">{error}</p> : null}
          <p className="policy-caption">By using Chai Khapa, you agree to our <a href="/terms/">Terms</a> and acknowledge our <a href="/privacy/">Privacy Policy</a>.</p>
        </section>
        <section className="how" id="how-it-works" aria-label="How Chai Khapa works">
          <div className="eyebrow">THE IDEA <span>/</span> THREE STEPS</div>
          <div className="steps"><div><span>01</span><h3>Someone pays</h3><p>One colleague handles the cash at the dhaba.</p></div><div><span>02</span><h3>Log the bill</h3><p>Enter the amount and tick the people who were there.</p></div><div><span>03</span><h3>Settle later</h3><p>See what each person owes when it's time to settle.</p></div></div>
          <p className="feature-note">Expense recording and settlements are being released in stages. Chai Khapa does not process payments.</p>
        </section>
      </main>
      <footer className="footer"><div>CHAI KHAPA <span>·</span> MADE FOR SHARED BREAKS</div><div><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a></div><span>© 2026 Chai Khapa</span></footer>
    </div>
  )
}
