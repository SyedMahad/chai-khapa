import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CSSProperties, FormEvent, ReactNode } from 'react'
import type { User } from '@supabase/supabase-js'
import { hasSupabaseConfig, supabase } from './lib/supabase'
import { allocateShares, displayName, formatPkr, initials, relativeDate, rupeesToPaisa } from './lib/finance'

type View = 'landing' | 'dashboard' | 'groups' | 'record' | 'activity' | 'notifications' | 'profile' | 'join'
type Profile = { user_id: string; first_name: string | null; last_name: string | null; name_confirmed_at: string | null }
type Group = { id: string; name: string; owner_user_id: string; created_at: string; timezone: string }
type Member = { group_id: string; user_id: string; role: string; left_at: string | null; name: string }
type Share = { user_id: string; share_paisa: number }
type Expense = { id: string; group_id: string; amount_paisa: number; paid_by_user_id: string; description: string | null; occurred_at: string; created_at: string; shares: Share[] }
type Balance = { user_id: string; first_name: string | null; last_name: string | null; total_paid_paisa: number; total_share_paisa: number; net_paisa: number }
type Notification = { id: string; group_id: string | null; type: string; title: string; body: string; target_type: string | null; target_id: string | null; read_at: string | null; created_at: string }

type IconName = 'grid' | 'users' | 'plus' | 'clock' | 'bell' | 'settings' | 'chevron' | 'arrow' | 'link' | 'check' | 'logout' | 'copy' | 'receipt' | 'cup' | 'menu' | 'close' | 'refresh'

function Icon({ name, size = 19 }: { name: IconName; size?: number }) {
  const paths: Record<IconName, ReactNode> = {
    grid: <><rect x="3" y="3" width="7" height="7" rx="1.2"/><rect x="14" y="3" width="7" height="7" rx="1.2"/><rect x="3" y="14" width="7" height="7" rx="1.2"/><rect x="14" y="14" width="7" height="7" rx="1.2"/></>,
    users: <><circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M17 5a3 3 0 0 1 0 6m1 3a5 5 0 0 1 3 5v1"/></>,
    plus: <path d="M12 5v14M5 12h14"/>, clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/></>,
    bell: <><path d="M18 8a6 6 0 0 0-12 0c0 7-3 8-3 9h18c0-1-3-2-3-9M10 21h4"/></>,
    settings: <><circle cx="12" cy="12" r="3"/><path d="M12 2v3m0 14v3M2 12h3m14 0h3M4.9 4.9 7 7m10 10 2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1"/></>,
    chevron: <path d="m7 10 5 5 5-5"/>, arrow: <path d="M5 12h14m-7-7 7 7-7 7"/>,
    link: <><path d="M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.2 1.2"/><path d="M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.2-1.2"/></>,
    check: <path d="m5 12 4 4L19 6"/>, logout: <><path d="M9 3H4v18h5M14 7l5 5-5 5M19 12H9"/></>,
    copy: <><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></>,
    receipt: <><path d="M5 3h14v18l-3-2-4 2-4-2-3 2z"/><path d="M9 9h6M9 13h6"/></>,
    cup: <><path d="M4 7h13v7a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6zM17 9h2a3 3 0 0 1 0 6h-2M7 2v2M12 2v2"/></>,
    menu: <path d="M4 7h16M4 12h16M4 17h16"/>, close: <path d="M5 5l14 14M19 5 5 19"/>,
    refresh: <><path d="M20 11a8 8 0 1 0-2 6M20 4v7h-7"/></>,
  }
  return <svg aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{paths[name]}</svg>
}

const routeFor = (v: View) => v === 'landing' ? '/' : v === 'dashboard' ? '/app' : `/app/${v}`
function readRoute(): { view: View; token: string | null } {
  const path = window.location.pathname.replace(/\/+$/, '')
  if (path.startsWith('/join/')) return { view: 'join', token: decodeURIComponent(path.slice(6)) }
  if (path === '/app' || path === '/app/dashboard') return { view: 'dashboard', token: null }
  const match = /^\/app\/(groups|record|activity|notifications|profile)$/.exec(path)
  if (match) return { view: match[1] as View, token: null }
  return { view: 'landing', token: null }
}

const money = (paisa: number | string) => formatPkr(paisa)
function Avatar({ name, size = 'sm' }: { name: string; size?: 'sm' | 'md' }) { return <span className={`avatar avatar-${size}`} aria-hidden="true">{initials(name)}</span> }
function Empty({ icon, title, detail, action }: { icon: IconName; title: string; detail: string; action?: ReactNode }) {
  return <div className="empty"><div className="empty-symbol"><Icon name={icon} size={25} /></div><h3>{title}</h3><p>{detail}</p>{action}</div>
}
function Spinner() { return <span className="spinner" aria-label="Loading" /> }
function SectionHead({ label, title, aside }: { label: string; title: string; aside?: ReactNode }) {
  return <div className="section-head"><div><p className="micro">{label}</p><h2>{title}</h2></div>{aside}</div>
}

export default function App() {
  const [authLoading, setAuthLoading] = useState(true)
  const [user, setUser] = useState<User | null>(null)
  const [route, setRoute] = useState(readRoute)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [groups, setGroups] = useState<Group[]>([])
  const [groupId, setGroupId] = useState<string | null>(null)
  const [members, setMembers] = useState<Member[]>([])
  const [expenses, setExpenses] = useState<Expense[]>([])
  const [balances, setBalances] = useState<Balance[]>([])
  const [notifications, setNotifications] = useState<Notification[]>([])
  const [unreadCount, setUnreadCount] = useState(0)
  const [notificationLimit, setNotificationLimit] = useState(30)
  const [hasMoreNotifications, setHasMoreNotifications] = useState(false)
  const [groupLoading, setGroupLoading] = useState(false)
  const [workspaceLoading, setWorkspaceLoading] = useState(false)
  const [error, setError] = useState('')
  const [toast, setToast] = useState('')
  const [mobileNav, setMobileNav] = useState(false)
  const groupRequestRef = useRef(0)

  const navigate = useCallback((view: View, path?: string) => {
    const target = path ?? routeFor(view)
    if (window.location.pathname !== target) window.history.pushState({}, '', target)
    setRoute(readRoute())
    setMobileNav(false)
    setError('')
    window.scrollTo({ top: 0, behavior: 'auto' })
  }, [])

  useEffect(() => {
    const onPop = () => setRoute(readRoute())
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  useEffect(() => {
    if (!supabase) { setAuthLoading(false); return }
    const client = supabase
    let active = true
    client.auth.getUser().then(({ data, error: authError }) => {
      if (!active) return
      setUser(data.user)
      if (authError && authError.name !== 'AuthSessionMissingError') setError(authError.message)
      setAuthLoading(false)
    }).catch((reason: unknown) => { if (active) { setAuthLoading(false); setError(messageOf(reason)) } })
    const { data: { subscription } } = client.auth.onAuthStateChange((_event, session) => {
      if (active) { setUser(session?.user ?? null); setAuthLoading(false) }
    })
    return () => { active = false; subscription.unsubscribe() }
  }, [])

  useEffect(() => {
    if (authLoading || !user || route.view !== 'landing') return
    window.history.replaceState({}, '', '/app')
    setRoute(readRoute())
  }, [authLoading, user, route.view])

  const refreshWorkspace = useCallback(async () => {
    if (!supabase || !user) return
    setWorkspaceLoading(true)
    try {
      const [p, g] = await Promise.all([
        supabase.from('profiles').select('user_id,first_name,last_name,name_confirmed_at').eq('user_id', user.id).single(),
        supabase.from('groups').select('id,name,owner_user_id,created_at,timezone').order('created_at', { ascending: false }),
      ])
      if (p.error) throw p.error
      if (g.error) throw g.error
      const list = (g.data ?? []) as Group[]
      setProfile(p.data as Profile)
      setGroups(list)
      setGroupId((old) => {
        const saved = localStorage.getItem(`chai-khapa-group:${user.id}`)
        const next = [old, saved, list[0]?.id].find((id) => id && list.some((group) => group.id === id)) ?? null
        return next
      })
    } catch (reason) { setError(messageOf(reason)) }
    finally { setWorkspaceLoading(false) }
  }, [user])

  useEffect(() => { void refreshWorkspace() }, [refreshWorkspace])

  const refreshGroup = useCallback(async () => {
    const request = ++groupRequestRef.current
    if (!supabase || !groupId) { setMembers([]); setExpenses([]); setBalances([]); setGroupLoading(false); return }
    setGroupLoading(true)
    setMembers([]); setExpenses([]); setBalances([])
    try {
      const [m, e, b] = await Promise.all([
        supabase.from('group_members').select('group_id,user_id,role,left_at').eq('group_id', groupId).is('left_at', null),
        supabase.from('expenses').select('id,group_id,amount_paisa,paid_by_user_id,description,occurred_at,created_at').eq('group_id', groupId).is('voided_at', null).order('occurred_at', { ascending: false }).limit(150),
        supabase.rpc('get_group_balances', { p_group_id: groupId }),
      ])
      if (m.error) throw m.error
      if (e.error) throw e.error
      if (b.error) throw b.error
      const active = (m.data ?? []) as Omit<Member, 'name'>[]
      const memberIds = [...new Set(active.map((item) => item.user_id))]
      const names = memberIds.length ? await supabase.from('profiles').select('user_id,first_name,last_name').in('user_id', memberIds) : { data: [], error: null }
      if (names.error) throw names.error
      const profileNames = new Map<string, string>((names.data ?? []).map((p: { user_id: string; first_name: string | null; last_name: string | null }) => [p.user_id, displayName(p)] as [string, string]))
      if (request !== groupRequestRef.current) return
      setMembers(active.map((member) => ({ ...member, name: profileNames.get(member.user_id) ?? 'Colleague' })))
      const rows = (e.data ?? []) as Omit<Expense, 'shares'>[]
      const shareResult = rows.length ? await supabase.from('expense_shares').select('expense_id,user_id,share_paisa').in('expense_id', rows.map((x) => x.id)) : { data: [], error: null }
      if (shareResult.error) throw shareResult.error
      const shares = new Map<string, Share[]>()
      for (const s of shareResult.data ?? []) {
        const id = s.expense_id as string
        shares.set(id, [...(shares.get(id) ?? []), { user_id: s.user_id as string, share_paisa: s.share_paisa as number }])
      }
      setExpenses(rows.map((row) => ({ ...row, shares: shares.get(row.id) ?? [] })))
      setBalances((b.data ?? []) as Balance[])
    } catch (reason) { if (request === groupRequestRef.current) setError(messageOf(reason)) }
    finally { if (request === groupRequestRef.current) setGroupLoading(false) }
  }, [groupId])

  useEffect(() => { void refreshGroup() }, [refreshGroup])

  const refreshNotifications = useCallback(async () => {
    if (!supabase || !user) return
    try {
      const [n, u] = await Promise.all([
        supabase.from('notifications').select('id,group_id,type,title,body,target_type,target_id,read_at,created_at').order('created_at', { ascending: false }).range(0, notificationLimit - 1),
        supabase.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null),
      ])
      if (n.error) throw n.error
      if (u.error) throw u.error
      setNotifications((n.data ?? []) as Notification[])
      setUnreadCount(u.count ?? 0)
      setHasMoreNotifications((n.data?.length ?? 0) === notificationLimit)
    } catch (reason) { setError(messageOf(reason)) }
  }, [user, notificationLimit])
  useEffect(() => { void refreshNotifications() }, [refreshNotifications])

  useEffect(() => {
    if (!supabase || !user) return
    const client = supabase
    // Realtime is best-effort; visibility/focus polling works even without publication setup.
    const ch = client.channel(`ck-notifications-${user.id}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications', filter: `recipient_user_id=eq.${user.id}` }, () => { void refreshNotifications() })
      .subscribe()
    const onFocus = () => { void refreshNotifications() }
    document.addEventListener('visibilitychange', onFocus)
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refreshNotifications() }, 90_000)
    return () => { document.removeEventListener('visibilitychange', onFocus); window.clearInterval(timer); void client.removeChannel(ch) }
  }, [user, refreshNotifications])

  useEffect(() => { if (!toast) return; const t = window.setTimeout(() => setToast(''), 4500); return () => window.clearTimeout(t) }, [toast])
  useEffect(() => { if (user && groupId) localStorage.setItem(`chai-khapa-group:${user.id}`, groupId) }, [user, groupId])

  const activeGroup = groups.find((g) => g.id === groupId) ?? null
  const me = balances.find((b) => b.user_id === user?.id)
  const memberName = (id: string) => members.find((m) => m.user_id === id)?.name ?? displayName(balances.find((b) => b.user_id === id))
  const recentTotal = expenses.reduce((sum, e) => sum + BigInt(e.amount_paisa), 0n)

  async function googleSignIn() {
    if (!supabase) return
    setError('')
    const callback = route.view === 'join' ? window.location.origin + window.location.pathname : window.location.origin + '/app'
    const { error: signInError } = await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: callback } })
    if (signInError) setError(signInError.message)
  }
  async function signOut() {
    if (!supabase) return
    const { error: signOutError } = await supabase.auth.signOut()
    if (signOutError) { setError(signOutError.message); return }
    setProfile(null); setGroups([]); setGroupId(null); setMembers([]); setExpenses([]); setBalances([]); setNotifications([])
    navigate('landing')
  }
  async function markRead(id: string) {
    if (!supabase) return
    const { error: readError } = await supabase.rpc('mark_notification_read', { p_notification_id: id })
    if (readError) { setError(readError.message); return }
    await refreshNotifications()
  }
  async function markAllRead() {
    if (!supabase) return
    const { error: readError } = await supabase.rpc('mark_all_notifications_read')
    if (readError) { setError(readError.message); return }
    await refreshNotifications()
  }

  if (authLoading) return <div className="auth-wait"><div className="mark">CK<span>.</span></div><Spinner /><p>Preparing your seat at the table</p></div>
  if (!user) return <Landing onSignIn={googleSignIn} loading={!hasSupabaseConfig} error={error} joinMode={route.view === 'join'} />
  if (!hasSupabaseConfig || !supabase) return <Landing onSignIn={googleSignIn} loading error="Supabase public environment variables are missing." />

  const client = supabase
  return <div className="workspace">
    <a className="skip-link" href="#content">Skip to content</a>
    <aside className={`sidebar ${mobileNav ? 'sidebar-open' : ''}`} aria-label="Main navigation">
      <div className="sidebar-top"><button className="brand-btn" onClick={() => navigate('dashboard')}><span className="mark small">CK<span>.</span></span><span className="brand-name">chai khapa<small>THE SHARED TAB</small></span></button><button className="icon-button sidebar-close" aria-label="Close menu" onClick={() => setMobileNav(false)}><Icon name="close" /></button></div>
      <div className="sidebar-section">YOUR SPACE</div>
      <nav className="side-links">
        <NavButton icon="grid" text="Overview" active={route.view === 'dashboard'} onClick={() => navigate('dashboard')} />
        <NavButton icon="users" text="Groups" active={route.view === 'groups'} onClick={() => navigate('groups')} />
        <NavButton icon="clock" text="Activity" active={route.view === 'activity'} onClick={() => navigate('activity')} />
        <NavButton icon="bell" text="Notifications" active={route.view === 'notifications'} badge={unreadCount} onClick={() => navigate('notifications')} />
      </nav>
      <div className="sidebar-section space-top">PREFERENCES</div>
      <nav className="side-links"><NavButton icon="settings" text="My profile" active={route.view === 'profile'} onClick={() => navigate('profile')} /></nav>
      <div className="sidebar-bottom"><div className="sidebar-tip"><Icon name="cup" size={22}/><p>Less counting.<br /><strong>More chai.</strong></p><span>✳</span></div><div className="account-mini"><Avatar name={displayName(profile)}/><span><strong>{displayName(profile)}</strong><small>{user.email ?? 'Google account'}</small></span><button className="icon-button" aria-label="Sign out" title="Sign out" onClick={() => void signOut()}><Icon name="logout" size={18}/></button></div></div>
    </aside>
    {mobileNav && <button className="nav-scrim" aria-label="Close menu" onClick={() => setMobileNav(false)} />}
    <div className="workspace-main">
      <header className="app-topbar"><div className="topbar-left"><button className="icon-button mobile-menu" aria-label="Open menu" onClick={() => setMobileNav(true)}><Icon name="menu" /></button><span className="crumb">WORKSPACE</span><span className="slash">/</span><span className="crumb-current">{route.view === 'dashboard' ? 'Overview' : route.view === 'join' ? 'Join group' : route.view.charAt(0).toUpperCase() + route.view.slice(1)}</span></div><div className="topbar-right"><span className="online-dot" aria-hidden="true"/><span className="workspace-status">PRIVATE GROUP SPACE</span><button className="icon-button bell-top" aria-label={`Notifications, ${unreadCount} unread`} onClick={() => navigate('notifications')}><Icon name="bell" />{unreadCount > 0 && <span className="top-badge"/>}</button><button className="avatar-button" aria-label="Open my profile" onClick={() => navigate('profile')}><Avatar name={displayName(profile)} /></button></div></header>
      <main id="content" className="page-content">
        {error && <div className="alert error-alert" role="alert"><span>{error}</span><button aria-label="Dismiss error" onClick={() => setError('')}><Icon name="close" size={17}/></button></div>}
        {route.view !== 'join' && !profile?.name_confirmed_at && !workspaceLoading && <div className="onboarding-bar"><div className="progress-ring" style={{ '--progress': '50%' } as CSSProperties}><span>1/2</span></div><div><strong>Make it yours.</strong><p>Confirm your first and last name to finish setting up your account.</p></div><button className="button button-outline" onClick={() => navigate('profile')}>Complete profile <Icon name="arrow" size={16}/></button></div>}
        {route.view === 'join' && <JoinPage token={route.token} onJoin={async (token) => { const { data, error: joinError } = await client.rpc('join_group', { p_token: token }); if (joinError) throw joinError; await refreshWorkspace(); setGroupId(data as string); setToast('Welcome to your new group!'); navigate('dashboard') }} />}
        {route.view === 'dashboard' && <>
          <div className="page-heading"><div><p className="micro accent">THE EVERYDAY CHAI LEDGER</p><h1>Good to see you<span className="punctuation">.</span></h1><p>Every cup counts. Every share is accounted for.</p></div><button className="button button-copper heading-cta" onClick={() => navigate('record')} disabled={!activeGroup}><Icon name="plus" size={19}/> Record a session</button></div>
          <GroupSwitcher groups={groups} groupId={groupId} onChange={setGroupId} onCreate={() => navigate('groups')}/>
          {workspaceLoading || groupLoading ? <LoadingPanel /> : !activeGroup ? <Empty icon="users" title="Your first chai group starts here" detail="Create a group, invite your colleagues, and start recording those dhaba runs." action={<button className="button button-copper" onClick={() => navigate('groups')}><Icon name="plus"/> Create your first group</button>}/> : <>
            <div className="stat-grid"><div className="stat-card feature-stat"><p className="stat-label">YOUR NET POSITION <span>ALL TIME</span></p><strong className={`stat-big ${(me?.net_paisa ?? 0) < 0 ? 'negative' : ''}`}>{money(me?.net_paisa ?? 0)}</strong><p className="stat-foot">{(me?.net_paisa ?? 0) > 0 ? 'You have covered more than your share.' : (me?.net_paisa ?? 0) < 0 ? 'Your share exceeds what you have paid.' : 'All balanced up for now.'}</p><span className="stat-decoration">✳</span></div><div className="stat-card"><p className="stat-label">RECENT SPENDING <span>LAST {expenses.length}</span></p><strong className="stat-big">{formatPkr(recentTotal)}</strong><p className="stat-foot">Across {expenses.length} {expenses.length === 1 ? 'session' : 'sessions'} in the recent ledger</p></div><div className="stat-card"><p className="stat-label">AT THE TABLE <span>ACTIVE</span></p><strong className="stat-big">{members.length.toString().padStart(2, '0')} <span className="stat-unit">people</span></strong><p className="stat-foot">Sharing the tab in {activeGroup.name}</p></div></div>
            <div className="dashboard-grid"><section className="panel"><SectionHead label="RECENTLY RECORDED" title="Latest sessions" aside={<button className="subtle-link" onClick={() => navigate('activity')}>View all <Icon name="arrow" size={15}/></button>}/>{expenses.length ? <div className="activity-list">{expenses.slice(0, 5).map((expense) => <ExpenseRow key={expense.id} expense={expense} payer={memberName(expense.paid_by_user_id)} onOpen={() => navigate('activity')}/>)}</div> : <Empty icon="cup" title="Nothing in the ledger yet" detail="Your first chai session is just one tap away." action={<button className="button button-outline" onClick={() => navigate('record')}>Record a session</button>}/>}</section><section className="panel"><SectionHead label="PEOPLE & POSITIONS" title="Group balances" /><p className="panel-description">Net positions before month-end settlement.</p><div className="balance-list">{balances.length ? balances.map((balance) => <div className="balance-line" key={balance.user_id}><Avatar name={displayName(balance)}/><span className="balance-person">{displayName(balance)}{balance.user_id === user.id && <small>YOU</small>}</span><span className={`balance-amount ${balance.net_paisa < 0 ? 'negative' : balance.net_paisa > 0 ? 'positive' : ''}`}>{balance.net_paisa > 0 ? '+' : ''}{money(balance.net_paisa)}</span></div>) : <p className="muted-small">Balances will appear after the first session.</p>}</div><div className="panel-bottom-note">Positive = paid more than share. Negative = paid less.</div></section></div>
          </>}
        </>}
        {route.view === 'groups' && <GroupsPage groups={groups} groupId={groupId} userId={user.id} onChoose={(id) => { setGroupId(id); navigate('dashboard') }} onGroupCreated={async (id) => { await refreshWorkspace(); setGroupId(id); setToast('Group created. Invite your colleagues!') }} onSuccess={setToast} />}
        {route.view === 'record' && <RecordPage group={activeGroup} members={members} expenses={expenses} userId={user.id} onBack={() => navigate('dashboard')} onSaved={async () => { await refreshGroup(); await refreshNotifications(); setToast('Session recorded. Everyone’s share has been saved.'); navigate('dashboard') }} />}
        {route.view === 'activity' && <ActivityPage group={activeGroup} expenses={expenses} members={members} loading={groupLoading} onRecord={() => navigate('record')} />}
        {route.view === 'notifications' && <NotificationsPage notifications={notifications} unreadCount={unreadCount} hasMore={hasMoreNotifications} onMore={() => setNotificationLimit((x) => x + 30)} onMarkRead={markRead} onMarkAll={markAllRead} onGo={(n) => { if (n.group_id && groups.some((g) => g.id === n.group_id)) setGroupId(n.group_id); navigate(n.target_type === 'expense' ? 'activity' : 'groups') }} />}
        {route.view === 'profile' && <ProfilePage user={user} profile={profile} onSave={async () => { await refreshWorkspace(); setToast('Your profile has been updated.') }} onSignOut={signOut} />}
        {route.view !== 'join' && <footer className="app-footer"><span>CHAI KHAPA <span className="footer-dot">✳</span> BUILT FOR THE SHARED BREAK</span><span><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a><span>© 2026</span></span></footer>}
      </main>
    </div>
    {toast && <div className="toast" role="status"><Icon name="check" size={18}/>{toast}<button aria-label="Dismiss" onClick={() => setToast('')}><Icon name="close" size={16}/></button></div>}
    <nav className="bottom-nav" aria-label="Mobile navigation"><NavMobile icon="grid" active={route.view === 'dashboard'} label="Home" onClick={() => navigate('dashboard')}/><NavMobile icon="users" active={route.view === 'groups'} label="Groups" onClick={() => navigate('groups')}/><button className="mobile-add" aria-label="Record chai session" onClick={() => navigate('record')}><Icon name="plus" size={24}/></button><NavMobile icon="clock" active={route.view === 'activity'} label="History" onClick={() => navigate('activity')}/><NavMobile icon="bell" active={route.view === 'notifications'} label="Inbox" count={unreadCount} onClick={() => navigate('notifications')}/></nav>
  </div>
}

function messageOf(error: unknown): string { return error instanceof Error ? error.message : typeof error === 'string' ? error : 'Something went wrong. Please try again.' }
function NavButton({ icon, text, active, onClick, badge }: { icon: IconName; text: string; active: boolean; onClick: () => void; badge?: number }) { return <button className={`nav-item ${active ? 'active' : ''}`} onClick={onClick} aria-current={active ? 'page' : undefined}><Icon name={icon}/><span>{text}</span>{badge ? <span className="nav-badge">{badge > 99 ? '99+' : badge}</span> : null}</button> }
function NavMobile({ icon, label, active, count, onClick }: { icon: IconName; label: string; active: boolean; count?: number; onClick: () => void }) { return <button onClick={onClick} aria-current={active ? 'page' : undefined} className={active ? 'active' : ''}><span className="mobile-icon"><Icon name={icon}/>{count ? <i className="mobile-dot"/> : null}</span><small>{label}</small></button> }
function LoadingPanel() { return <div className="loading-panel"><Spinner /><p>Getting your latest chai records…</p></div> }
function GroupSwitcher({ groups, groupId, onChange, onCreate }: { groups: Group[]; groupId: string | null; onChange: (value: string) => void; onCreate: () => void }) { return <div className="group-switcher"><div><span className="switcher-icon"><Icon name="users" size={17}/></span><label htmlFor="group-selection">CURRENT GROUP</label>{groups.length ? <select id="group-selection" value={groupId ?? ''} onChange={(e) => onChange(e.target.value)}>{groups.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}</select> : <span className="switcher-empty">No group selected</span>}</div><button className="subtle-link" onClick={onCreate}>{groups.length ? 'Manage groups' : 'Create a group'} <Icon name="arrow" size={15}/></button></div> }
function ExpenseRow({ expense, payer, onOpen }: { expense: Expense; payer: string; onOpen: () => void }) { return <button className="expense-row" onClick={onOpen}><span className="expense-icon"><Icon name="cup" size={20}/></span><span className="expense-info"><strong>{expense.description || 'Chai session'}</strong><small>{payer} paid <span>·</span> {relativeDate(expense.occurred_at)}</small></span><span className="expense-end"><strong>{money(expense.amount_paisa)}</strong><small>{expense.shares.length} {expense.shares.length === 1 ? 'person' : 'people'}</small></span></button> }

function Landing({ onSignIn, loading, error, joinMode }: { onSignIn: () => void; loading: boolean; error?: string; joinMode?: boolean }) {
  return <div className="landing"><a className="skip-link" href="#main">Skip to content</a><header className="landing-nav"><a className="landing-brand" href="/"><span className="mark small">CK<span>.</span></span><span>CHAI KHAPA</span></a><nav aria-label="Public navigation"><a href="#how-it-works">How it works</a><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a></nav></header><main id="main" className="landing-main"><p className="micro accent">MADE FOR THE EVERYDAY CHAI BREAK</p><div className="landing-grid"><div><h1>Good chai.<br/><em>Clear hisaab.</em></h1><p className="landing-lead">One person pays at the dhaba. Everyone settles their share later. The good stuff stays simple.</p><div className="landing-actions">{!loading ? <button className="button button-copper large" onClick={onSignIn}>Continue with Google <Icon name="arrow"/></button> : <div className="alert error-alert">Add your public Supabase environment variables to enable sign-in.</div>}<small>No spreadsheets. No awkward reminders.</small></div>{error && <p className="form-error" role="alert">{error}</p>}{joinMode && <p className="landing-join-note">You have a group invite. Sign in to accept it.</p>}</div><div className="landing-side"><div className="landing-visual"><div className="landing-ticket-top"><span>CHAI KHAPA / DAILY LEDGER</span><span>✳</span></div><div className="landing-visual-cup"><Icon name="cup" size={68}/></div><div className="ticket-bottom"><span>THE TAB <small>EVERYONE'S COVERED</small></span><strong>Rs. 350.00</strong></div><div className="ticket-split">5 colleagues <span>Rs. 70 each</span></div></div><p className="landing-quote">“Tu chai pee, hisaab app mein hai.”</p></div></div><section id="how-it-works" className="landing-how"><p className="micro">THE PROCESS / THREE SMALL STEPS</p><div className="landing-steps"><div><span>01</span><h2>Someone pays.</h2><p>One colleague handles the cash at the dhaba.</p></div><div><span>02</span><h2>Log the bill.</h2><p>Enter the amount and tick who was there.</p></div><div><span>03</span><h2>Settle later.</h2><p>Everyone can see exactly what they've paid and consumed.</p></div></div></section></main><footer className="landing-footer"><span>CHAI KHAPA · GOOD CHAI, CLEAR HISAAB.</span><div><a href="/privacy/">Privacy Policy</a><a href="/terms/">Terms of Service</a></div><span>© 2026</span></footer></div>
}

function GroupsPage({ groups, groupId, userId, onChoose, onGroupCreated, onSuccess }: { groups: Group[]; groupId: string | null; userId: string; onChoose: (id: string) => void; onGroupCreated: (id: string) => Promise<void>; onSuccess: (text: string) => void }) {
  const [name, setName] = useState('')
  const [creating, setCreating] = useState(false)
  const [inviteGroup, setInviteGroup] = useState<string | null>(null)
  const [inviteLink, setInviteLink] = useState('')
  const [error, setError] = useState('')
  async function createGroup(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); if (!supabase) return
    setError(''); setCreating(true)
    try { const { data, error: rpcError } = await supabase.rpc('create_group', { p_name: name.trim() }); if (rpcError) throw rpcError; await onGroupCreated(data as string); setName('') }
    catch (reason) { setError(messageOf(reason)) } finally { setCreating(false) }
  }
  async function generateInvite(id: string) {
    if (!supabase) return
    setError(''); setInviteLink(''); setInviteGroup(id)
    try { const { data, error: rpcError } = await supabase.rpc('create_group_invite', { p_group_id: id, p_max_uses: 25, p_expiry_hours: 168 }); if (rpcError) throw rpcError; const token = (data as { token: string }).token; setInviteLink(`${window.location.origin}/join/${token}`) }
    catch (reason) { setError(messageOf(reason)) }
  }
  async function copyInvite() {
    try { await navigator.clipboard.writeText(inviteLink); onSuccess('Invite link copied to clipboard.') }
    catch { setError('Could not copy automatically. Select the link and copy it.') }
  }
  return <><div className="page-heading short"><div><p className="micro accent">YOUR CIRCLES</p><h1>Chai groups<span className="punctuation">.</span></h1><p>A separate ledger for every group of colleagues.</p></div></div><div className="two-col"><section className="panel"><SectionHead label="YOUR GROUPS" title={`${groups.length} ${groups.length === 1 ? 'group' : 'groups'}`} />{groups.length ? <div className="groups-list">{groups.map((g) => <div className={`group-card ${groupId === g.id ? 'selected' : ''}`} key={g.id}><div className="group-icon"><Icon name="users"/></div><div className="group-card-content"><strong>{g.name}</strong><small>{g.owner_user_id === userId ? 'YOU’RE THE OWNER' : 'MEMBER'} · ASIA/KARACHI</small></div><div className="group-card-actions"><button className="icon-button" title="Open group" aria-label={`Open ${g.name}`} onClick={() => onChoose(g.id)}><Icon name="arrow" size={19}/></button>{g.owner_user_id === userId && <button className="icon-button" title="Invite colleagues" aria-label={`Invite to ${g.name}`} onClick={() => void generateInvite(g.id)}><Icon name="link" size={18}/></button>}</div></div>)}</div> : <Empty icon="users" title="No groups yet" detail="Make a home for your chai crew." />}</section><section className="panel create-panel"><SectionHead label="START SOMETHING" title="Create a new group" /><p className="panel-description">Give your group a name. You can share an invite link with the team immediately afterward.</p><form onSubmit={(e) => void createGroup(e)}><label className="field-label" htmlFor="group-name">GROUP NAME</label><input id="group-name" placeholder="e.g. Office Chai Gang" maxLength={80} minLength={2} required value={name} onChange={(e) => setName(e.target.value)} /><button className="button button-copper form-submit" disabled={creating || name.trim().length < 2}>{creating ? <Spinner/> : <Icon name="plus" size={18}/>} Create group</button></form>{inviteGroup && <div className="invite-box"><p className="micro">INVITE LINK · VALID FOR 7 DAYS</p>{inviteLink ? <><input aria-label="New invite link" value={inviteLink} readOnly onFocus={(e) => e.currentTarget.select()}/><button className="button button-outline" onClick={() => void copyInvite()}><Icon name="copy" size={17}/> Copy invitation</button><p className="muted-small">The invitation URL is only shown here once. Anyone holding it can join (up to 25 uses).</p></> : <p className="muted-small">Generating your invite…</p>}</div>}{error && <p className="form-error" role="alert">{error}</p>}</section></div></>
}

function JoinPage({ token, onJoin }: { token: string | null; onJoin: (token: string) => Promise<void> }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  async function accept() { if (!token) return; setBusy(true); setError(''); try { await onJoin(token) } catch (reason) { setError(messageOf(reason)) } finally { setBusy(false) } }
  return <div className="join-wrap"><div className="join-card"><div className="empty-symbol"><Icon name="users" size={30}/></div><p className="micro accent">A SEAT AT THE TABLE</p><h1>You're invited<span className="punctuation">.</span></h1><p>Someone has shared a Chai Khapa group invitation with you. Join to see sessions and contribute to the group's ledger.</p>{token ? <button className="button button-copper" onClick={() => void accept()} disabled={busy}>{busy ? <Spinner/> : <Icon name="check"/>} Accept invitation</button> : <p className="form-error">This invitation URL is invalid.</p>}{error && <p className="form-error" role="alert">{error}</p>}</div></div>
}

function RecordPage({ group, members, expenses, userId, onBack, onSaved }: { group: Group | null; members: Member[]; expenses: Expense[]; userId: string; onBack: () => void; onSaved: () => Promise<void> }) {
  const [amount, setAmount] = useState('')
  const [description, setDescription] = useState('')
  const [chosen, setChosen] = useState<string[]>([userId])
  const [requestId, setRequestId] = useState(() => crypto.randomUUID())
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  const [initializedGroup, setInitializedGroup] = useState<string | null>(null)
  useEffect(() => {
    if (!group || !members.length) return
    if (initializedGroup === group.id) return
    const eligible = new Set(members.map((m) => m.user_id))
    const previous = expenses[0]?.shares.map((s) => s.user_id).filter((id) => eligible.has(id)) ?? []
    setChosen([...new Set([userId, ...previous])]); setInitializedGroup(group.id); setRequestId(crypto.randomUUID())
  }, [group, expenses, members, userId, initializedGroup])
  const amountPaisa = useMemo(() => { try { return rupeesToPaisa(amount) } catch { return null } }, [amount])
  const splits = useMemo(() => amountPaisa ? allocateShares(amountPaisa, chosen) : {}, [amountPaisa, chosen])
  function toggle(id: string) { if (id === userId) return; setChosen((current) => current.includes(id) ? current.filter((x) => x !== id) : [...current, id]) }
  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault(); if (!supabase || !group || !amountPaisa || chosen.length === 0) return
    setBusy(true); setError('')
    try {
      const { error: rpcError } = await supabase.rpc('record_expense', { p_group_id: group.id, p_amount_paisa: amountPaisa, p_participant_user_ids: [...chosen].sort(), p_request_id: requestId, p_description: description.trim() || null, p_occurred_at: null })
      if (rpcError) throw rpcError
      setRequestId(crypto.randomUUID()); await onSaved()
    } catch (reason) { setError(messageOf(reason)) } finally { setBusy(false) }
  }
  if (!group) return <><div className="page-heading short"><div><h1>Record chai<span className="punctuation">.</span></h1></div></div><Empty icon="users" title="Choose a group first" detail="Create or join a group before recording your first session." action={<button className="button button-outline" onClick={onBack}>Back to overview</button>}/></>
  return <><div className="page-heading short"><div><p className="micro accent">NEW ENTRY / {group.name.toUpperCase()}</p><h1>Record chai<span className="punctuation">.</span></h1><p>Amount first. Check who's here. Done.</p></div></div><form className="record-layout" onSubmit={(e) => void save(e)}><section className="panel record-main"><SectionHead label="01 / THE BILL" title="How much was it?"/><label className="field-label" htmlFor="amount">TOTAL AMOUNT (PKR)</label><div className="amount-input"><span>Rs.</span><input id="amount" autoFocus inputMode="decimal" pattern="[0-9]+(\.[0-9]{1,2})?" placeholder="350" value={amount} onChange={(e) => setAmount(e.target.value)} required aria-describedby="amount-help" /></div><p id="amount-help" className="field-help">Enter rupees. You can include up to 2 decimal places.</p><div className="divider"/><SectionHead label="02 / THE TABLE" title="Who was there?" aside={<span className="people-count">{chosen.length} selected</span>}/><p className="panel-description">Attendees are preselected from the previous session. Make any changes you need. You're always included as the payer.</p>{members.length ? <div className="attendee-grid">{members.map((m) => <label key={m.user_id} className={`attendee ${chosen.includes(m.user_id) ? 'checked' : ''}`}><input type="checkbox" checked={chosen.includes(m.user_id)} disabled={m.user_id === userId} onChange={() => toggle(m.user_id)}/><Avatar name={m.name}/><span>{m.name}{m.user_id === userId ? <small>YOU · PAID</small> : null}</span><span className="custom-check"><Icon name="check" size={14}/></span></label>)}</div> : <p className="muted-small">Loading members…</p>}<div className="divider"/><label className="field-label" htmlFor="description">SESSION NOTE <span className="optional">OPTIONAL</span></label><input id="description" placeholder="e.g. Afternoon chai" maxLength={240} value={description} onChange={(e) => setDescription(e.target.value)} />{error && <p className="form-error" role="alert">{error}</p>}</section><aside className="record-summary"><div className="summary-top"><span className="micro">SESSION SUMMARY</span><Icon name="receipt" size={22}/></div><div className="summary-amount">{amountPaisa ? money(amountPaisa) : 'Rs. —'}</div><p className="muted-small">{chosen.length} {chosen.length === 1 ? 'person' : 'people'} · paid by you · equally split</p><div className="summary-splits">{chosen.map((id) => <div key={id}><span>{members.find((m) => m.user_id === id)?.name ?? 'Colleague'}</span><strong>{amountPaisa ? money(splits[id] ?? 0) : '—'}</strong></div>)}</div><button type="submit" className="button button-copper full" disabled={!amountPaisa || !chosen.length || busy}>{busy ? <Spinner/> : <Icon name="check" size={18}/>} {busy ? 'Saving session…' : 'Save this session'}</button><button type="button" className="button button-text full" onClick={onBack}>Cancel</button><p className="summary-note">The bill, individual shares, and notifications are saved together. No one needs to pay right now.</p></aside></form></>
}

function ActivityPage({ group, expenses, members, loading, onRecord }: { group: Group | null; expenses: Expense[]; members: Member[]; loading: boolean; onRecord: () => void }) {
  const [expanded, setExpanded] = useState<string | null>(null)
  const memberName = (id: string) => members.find((m) => m.user_id === id)?.name ?? 'Colleague'
  return <><div className="page-heading short"><div><p className="micro accent">EVERY CUP, ACCOUNTED FOR</p><h1>Session history<span className="punctuation">.</span></h1><p>{group ? `The shared ledger for ${group.name}.` : 'Select a group to see its sessions.'}</p></div><button className="button button-copper heading-cta" onClick={onRecord} disabled={!group}><Icon name="plus"/> Record session</button></div><div className="panel activity-panel"><SectionHead label="THE RECORD" title="All sessions" aside={<span className="people-count">Latest {expenses.length} records</span>}/>{loading ? <LoadingPanel/> : !group ? <Empty icon="users" title="No group selected" detail="Choose or create a group to view the ledger."/> : expenses.length ? <div className="activity-list full-list">{expenses.map((expense) => <div className="activity-entry" key={expense.id}><button className="expense-row" onClick={() => setExpanded(expanded === expense.id ? null : expense.id)} aria-expanded={expanded === expense.id}><span className="expense-icon"><Icon name="cup"/></span><span className="expense-info"><strong>{expense.description || 'Chai session'}</strong><small>{memberName(expense.paid_by_user_id)} paid <span>·</span> {relativeDate(expense.occurred_at)}</small></span><span className="expense-end"><strong>{money(expense.amount_paisa)}</strong><small>{expense.shares.length} people <Icon name="chevron" size={14}/></small></span></button>{expanded === expense.id && <div className="activity-shares"><p className="micro">INDIVIDUAL SHARES</p>{expense.shares.map((share) => <div key={share.user_id}><span>{memberName(share.user_id)}</span><strong>{money(share.share_paisa)}</strong></div>)}</div>}</div>)}</div> : <Empty icon="receipt" title="No sessions recorded" detail="As soon as someone adds a bill, it will show up here." action={<button className="button button-copper" onClick={onRecord}>Record a session</button>}/>}<p className="panel-bottom-note">Showing up to 150 recent sessions in this release. Full history pagination will follow.</p></div></>
}

function NotificationsPage({ notifications, unreadCount, hasMore, onMore, onMarkRead, onMarkAll, onGo }: { notifications: Notification[]; unreadCount: number; hasMore: boolean; onMore: () => void; onMarkRead: (id: string) => Promise<void>; onMarkAll: () => Promise<void>; onGo: (n: Notification) => void }) {
  return <><div className="page-heading short"><div><p className="micro accent">WHAT'S NEW</p><h1>Your inbox<span className="punctuation">.</span></h1><p>Chai updates, group activity, and things that need your attention.</p></div></div><section className="panel notification-panel"><SectionHead label="NOTIFICATIONS" title={unreadCount ? `${unreadCount} unread` : 'All caught up'} aside={unreadCount ? <button className="subtle-link" onClick={() => void onMarkAll()}><Icon name="check" size={15}/> Mark all as read</button> : undefined}/>{notifications.length ? <div className="notification-list">{notifications.map((n) => <div key={n.id} className={`notification-item ${!n.read_at ? 'unread' : ''}`}><div className="notification-symbol"><Icon name={n.type === 'expense_created' ? 'cup' : 'users'} size={20}/></div><button className="notification-content" onClick={() => { void onMarkRead(n.id); onGo(n) }}><strong>{n.title}</strong><p>{n.body}</p><small>{relativeDate(n.created_at)}</small></button><div className="notification-actions">{!n.read_at && <button className="read-btn" title="Mark as read" aria-label={`Mark ${n.title} as read`} onClick={() => void onMarkRead(n.id)}><Icon name="check" size={16}/></button>}{!n.read_at && <span className="unread-pip" aria-hidden="true"/>}</div></div>)}</div> : <Empty icon="bell" title="It's quiet in here" detail="When someone records a session or joins your group, you'll see it here."/>}{hasMore && <button className="button button-outline load-more" onClick={onMore}>Load more notifications <Icon name="arrow" size={15}/></button>}</section></>
}

function ProfilePage({ user, profile, onSave, onSignOut }: { user: User; profile: Profile | null; onSave: () => Promise<void>; onSignOut: () => Promise<void> }) {
  const metadataName = String(user.user_metadata?.full_name ?? user.user_metadata?.name ?? '').trim().split(/\s+/)
  const [first, setFirst] = useState(profile?.first_name || metadataName[0] || '')
  const [last, setLast] = useState(profile?.last_name || metadataName.slice(1).join(' ') || '')
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  useEffect(() => { if (profile?.name_confirmed_at) { setFirst(profile.first_name || ''); setLast(profile.last_name || '') } }, [profile])
  async function save(e: FormEvent<HTMLFormElement>) { e.preventDefault(); if (!supabase) return; setBusy(true); setError(''); try { const { error: rpcError } = await supabase.rpc('complete_profile', { p_first_name: first.trim(), p_last_name: last.trim() }); if (rpcError) throw rpcError; await onSave() } catch (reason) { setError(messageOf(reason)) } finally { setBusy(false) } }
  return <><div className="page-heading short"><div><p className="micro accent">ACCOUNT DETAILS</p><h1>Your profile<span className="punctuation">.</span></h1><p>The name your chai group will recognize.</p></div></div><div className="two-col profile-grid"><section className="panel"><SectionHead label="YOUR DETAILS" title="The basics"/><form onSubmit={(e) => void save(e)}><div className="profile-avatar-row"><Avatar name={displayName(profile) === 'Colleague' ? `${first} ${last}` : displayName(profile)} size="md"/><div><strong>{profile?.name_confirmed_at ? 'Profile confirmed' : 'One last introduction'}</strong><p className="muted-small">These names appear in your group ledger.</p></div></div><div className="input-grid"><div><label className="field-label" htmlFor="first-name">FIRST NAME</label><input id="first-name" maxLength={80} required value={first} onChange={(e) => setFirst(e.target.value)}/></div><div><label className="field-label" htmlFor="last-name">LAST NAME</label><input id="last-name" maxLength={80} required value={last} onChange={(e) => setLast(e.target.value)}/></div></div><label className="field-label" htmlFor="account-email">GOOGLE ACCOUNT</label><input id="account-email" readOnly value={user.email ?? ''} /><p className="field-help">Your email comes from Google and isn't editable here.</p>{error && <p className="form-error" role="alert">{error}</p>}<button className="button button-copper form-submit" type="submit" disabled={busy || !first.trim() || !last.trim()}>{busy ? <Spinner/> : <Icon name="check" size={17}/>} {profile?.name_confirmed_at ? 'Save changes' : 'Confirm my name'}</button></form></section><aside className="panel profile-side"><SectionHead label="YOUR ACCOUNT" title="Getting started"/><div className="setup-progress"><span className="progress-ring large-ring" style={{ '--progress': profile?.name_confirmed_at ? '100%' : '50%' } as CSSProperties}><strong>{profile?.name_confirmed_at ? '2/2' : '1/2'}</strong></span><div><strong>{profile?.name_confirmed_at ? 'All set.' : 'Nearly there.'}</strong><p className="muted-small">Google Sign-In is connected. Confirm your name to complete the essentials.</p></div></div><div className="setup-step"><Icon name="check" size={18}/> Google account connected</div><div className={`setup-step ${profile?.name_confirmed_at ? '' : 'pending'}`}><Icon name={profile?.name_confirmed_at ? 'check' : 'clock'} size={18}/> Name confirmed</div><div className="divider"/><p className="muted-small">Raast and wallet details will be added with month-end settlements. They're optional, not part of profile completion.</p><button className="button button-outline" onClick={() => void onSignOut()}><Icon name="logout" size={17}/> Sign out</button></aside></div></>
}
