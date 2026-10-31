import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CSSProperties, FormEvent, ReactNode } from 'react'
import type { User } from '@supabase/supabase-js'
import { hasSupabaseConfig, supabase } from './lib/supabase'
import { allocateShares, displayName, formatPkr, initials, relativeDate, rupeesToPaisa } from './lib/finance'
import { invitationUrl, oauthReturnUrl } from './lib/urls'
import { computeTransfers } from './lib/settlements'
import { useInstallApp } from './lib/install'

type View = 'landing' | 'dashboard' | 'groups' | 'group' | 'record' | 'activity' | 'dues' | 'notifications' | 'profile' | 'join'
type Profile = { user_id: string; first_name: string | null; last_name: string | null; name_confirmed_at: string | null }
type Group = { id: string; name: string; owner_user_id: string; created_at: string; timezone: string; archived_at?: string | null }
type Member = { group_id: string; user_id: string; role: string; left_at: string | null; name: string }
type Share = { user_id: string; share_paisa: number }
type Expense = { id: string; group_id: string; amount_paisa: number; paid_by_user_id: string; description: string | null; occurred_at: string; created_at: string; shares: Share[] }
type Balance = { user_id: string; first_name: string | null; last_name: string | null; total_paid_paisa: number; total_share_paisa: number; net_paisa: number }
type GroupOverview = { id: string; name: string; net: number; memberCount: number; sessionCount: number; archived: boolean; balances: Balance[] }
type Notification = { id: string; group_id: string | null; type: string; title: string; body: string; target_type: string | null; target_id: string | null; read_at: string | null; created_at: string }
type SettlementPeriod = { id: string; group_id: string; period_month: string; start_at: string; end_at: string; closed_at: string }
type SettlementTransfer = { id: string; period_id: string; group_id: string; debtor_user_id: string; creditor_user_id: string; amount_paisa: number; status: 'unpaid' | 'awaiting_confirmation' | 'confirmed'; confirmed_at: string | null }
type PaymentClaim = { id: string; transfer_id: string; actual_paid_paisa: number; rounding_adjustment_paisa: number; claimed_by_user_id: string; status: 'pending' | 'confirmed' | 'rejected'; created_at: string }


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
  const detail = /^\/app\/groups\/([0-9a-f-]{36})$/.exec(path)
  if (detail) return { view: 'group', token: detail[1] }
  const match = /^\/app\/(groups|record|activity|dues|notifications|profile)$/.exec(path)
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
  const [settlementPeriods, setSettlementPeriods] = useState<SettlementPeriod[]>([])
  const [settlementTransfers, setSettlementTransfers] = useState<SettlementTransfer[]>([])
  const [paymentClaims, setPaymentClaims] = useState<PaymentClaim[]>([])
  const [settlementLoading, setSettlementLoading] = useState(false)
  const settlementRequestRef = useRef(0)
  const [unreadCount, setUnreadCount] = useState(0)
  const [notificationLimit, setNotificationLimit] = useState(30)
  const [hasMoreNotifications, setHasMoreNotifications] = useState(false)
  const [groupLoading, setGroupLoading] = useState(false)
  const [overview, setOverview] = useState<GroupOverview[]>([])
  const [overviewLoading, setOverviewLoading] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const workspaceRequestRef = useRef(0)
  const overviewRequestRef = useRef(0)
  const notificationRequestRef = useRef(0)
  const install = useInstallApp()
  const refreshNotificationsRef = useRef<() => Promise<void>>(async () => {})
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
    const request = ++workspaceRequestRef.current
    setWorkspaceLoading(true)
    try {
      const [p, g] = await Promise.all([
        supabase.from('profiles').select('user_id,first_name,last_name,name_confirmed_at').eq('user_id', user.id).single(),
        supabase.from('groups').select('id,name,owner_user_id,created_at,timezone,archived_at').order('created_at', { ascending: false }),
      ])
      if (p.error) throw p.error
      if (g.error) throw g.error
      const list = (g.data ?? []) as Group[]
      if (request !== workspaceRequestRef.current) return
      setProfile(p.data as Profile)
      setGroups(list)
      setGroupId((old) => {
        const saved = localStorage.getItem(`chai-khapa-group:${user.id}`)
        const next = [old, saved, list[0]?.id].find((id) => id && list.some((group) => group.id === id)) ?? null
        return next
      })
    } catch (reason) { if (request === workspaceRequestRef.current) setError(messageOf(reason)) }
    finally { if (request === workspaceRequestRef.current) setWorkspaceLoading(false) }
  }, [user])

  useEffect(() => {
    workspaceRequestRef.current++; overviewRequestRef.current++; groupRequestRef.current++; notificationRequestRef.current++; settlementRequestRef.current++
    setProfile(null); setGroups([]); setGroupId(null); setOverview([]); setMembers([]); setExpenses([]); setBalances([]); setNotifications([]); setSettlementPeriods([]); setSettlementTransfers([]); setPaymentClaims([])
    if (user) void refreshWorkspace()
  }, [user?.id]) // On sign-in/out, discard another user's data; not on ordinary rerenders.

  useEffect(() => {
    if (!user || route.view !== 'group' || !route.token) return
    if (groups.some(g => g.id === route.token) && groupId !== route.token) setGroupId(route.token)
  }, [route.view, route.token, groups, groupId, user?.id])

  const refreshGroup = useCallback(async () => {
    const request = ++groupRequestRef.current
    if (!supabase || !groupId) { setMembers([]); setExpenses([]); setBalances([]); setGroupLoading(false); return }
    setGroupLoading(true)
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
      setMembers(active.map((member) => {
        const savedName = profileNames.get(member.user_id)
        const isMe = member.user_id === user?.id
        const currentName = isMe && profile ? displayName(profile) : savedName
        return { ...member, name: currentName && currentName !== 'Colleague' ? currentName : (isMe ? 'You (complete profile)' : 'Name not set') }
      }))
      const rows = (e.data ?? []) as Omit<Expense, 'shares'>[]
      const shareResult = rows.length ? await supabase.from('expense_shares').select('expense_id,user_id,share_paisa').in('expense_id', rows.map((x) => x.id)) : { data: [], error: null }
      if (shareResult.error) throw shareResult.error
      if (request !== groupRequestRef.current) return
      const shares = new Map<string, Share[]>()
      for (const s of shareResult.data ?? []) {
        const id = s.expense_id as string
        shares.set(id, [...(shares.get(id) ?? []), { user_id: s.user_id as string, share_paisa: s.share_paisa as number }])
      }
      setExpenses(rows.map((row) => ({ ...row, shares: shares.get(row.id) ?? [] })))
      setBalances((b.data ?? []) as Balance[])
    } catch (reason) { if (request === groupRequestRef.current) setError(messageOf(reason)) }
    finally { if (request === groupRequestRef.current) setGroupLoading(false) }
  }, [groupId, user?.id, profile?.first_name, profile?.last_name])

  useEffect(() => { setMembers([]); setExpenses([]); setBalances([]); void refreshGroup() }, [groupId])
  useEffect(() => { if (groupId) void refreshGroup() }, [route.view])

  const refreshOverview = useCallback(async () => {
    const request = ++overviewRequestRef.current
    if (!supabase || !user || !groups.length) { setOverview([]); setOverviewLoading(false); return }
    setOverviewLoading(true)
    try {
      const results = await Promise.all(groups.map(async (g): Promise<GroupOverview> => {
        const [b, m, e] = await Promise.all([
          supabase!.rpc('get_group_balances', { p_group_id: g.id }),
          supabase!.from('group_members').select('*', { count: 'exact', head: true }).eq('group_id', g.id).is('left_at', null),
          supabase!.from('expenses').select('*', { count: 'exact', head: true }).eq('group_id', g.id).is('voided_at', null),
        ])
        if (b.error) throw b.error
        if (m.error) throw m.error
        if (e.error) throw e.error
        const bs = (b.data ?? []) as Balance[]
        return { id: g.id, name: g.name, net: Number(bs.find(x => x.user_id === user.id)?.net_paisa ?? 0), memberCount: m.count ?? 0, sessionCount: e.count ?? 0, archived: Boolean((g as Group & { archived_at?: string | null }).archived_at), balances: bs }
      }))
      if (request === overviewRequestRef.current) setOverview(results)
    } catch (reason) { if (request === overviewRequestRef.current) setError(messageOf(reason)) }
    finally { if (request === overviewRequestRef.current) setOverviewLoading(false) }
  }, [groups, user?.id])
  useEffect(() => { void refreshOverview() }, [refreshOverview])
  useEffect(() => { if (user && (route.view === 'groups' || route.view === 'group')) void refreshWorkspace() }, [route.view, user?.id])
  useEffect(() => { if (user && route.view === 'dues') void refreshOverview() }, [route.view, user?.id])

  const refreshSettlements = useCallback(async () => {
    const req = ++settlementRequestRef.current
    if (!supabase || !user || !groups.length) {
      setSettlementPeriods([]); setSettlementTransfers([]); setPaymentClaims([]); setSettlementLoading(false); return
    }
    setSettlementLoading(true)
    try {
      const ids = groups.map(g => g.id)
      const [p, t] = await Promise.all([
        supabase.from('settlement_periods').select('id,group_id,period_month,start_at,end_at,closed_at').in('group_id', ids).order('period_month', { ascending: false }),
        supabase.from('settlement_transfers').select('id,period_id,group_id,debtor_user_id,creditor_user_id,amount_paisa,status,confirmed_at').in('group_id', ids),
      ])
      if (p.error) throw p.error
      if (t.error) throw t.error
      const transferRows = (t.data ?? []) as SettlementTransfer[]
      const relevantIds = transferRows.filter(row => row.debtor_user_id === user.id || row.creditor_user_id === user.id).map(row => row.id)
      const claims = relevantIds.length ? await supabase.from('settlement_payment_claims')
        .select('id,transfer_id,actual_paid_paisa,rounding_adjustment_paisa,claimed_by_user_id,status,created_at')
        .in('transfer_id', relevantIds).order('created_at', { ascending: false }) : { data: [] as PaymentClaim[], error: null }
      if (claims.error) throw claims.error
      if (req !== settlementRequestRef.current) return
      setSettlementPeriods((p.data ?? []) as SettlementPeriod[])
      setSettlementTransfers(transferRows)
      setPaymentClaims((claims.data ?? []) as PaymentClaim[])
    } catch (reason) { if (req === settlementRequestRef.current) setError(messageOf(reason)) }
    finally { if (req === settlementRequestRef.current) setSettlementLoading(false) }
  }, [groups, user?.id])
  useEffect(() => { if (user && route.view === 'dues') void refreshSettlements() }, [user?.id, route.view, refreshSettlements])

  // Refresh independently changing data on focus, reconnect and periodically while visible.
  // Every request has a request generation: old responses cannot overwrite the active group.
  useEffect(() => {
    if (!user) return
    let last = 0
    const revalidate = () => {
      if (document.visibilityState === 'hidden' || !navigator.onLine || Date.now() - last < 12_000) return
      last = Date.now()
      setRefreshing(true)
      void Promise.allSettled([refreshWorkspace(), refreshGroup(), refreshOverview(), refreshNotificationsRef.current(), refreshSettlements()]).finally(() => setRefreshing(false))
    }
    window.addEventListener('focus', revalidate)
    window.addEventListener('online', revalidate)
    document.addEventListener('visibilitychange', revalidate)
    const timer = window.setInterval(revalidate, 60_000)
    return () => { window.removeEventListener('focus', revalidate); window.removeEventListener('online', revalidate); document.removeEventListener('visibilitychange', revalidate); clearInterval(timer) }
  }, [user?.id, refreshWorkspace, refreshGroup, refreshOverview, refreshSettlements])
  const refreshNotifications = useCallback(async () => {
    if (!supabase || !user) return
    const request = ++notificationRequestRef.current
    try {
      const [n, u] = await Promise.all([
        supabase.from('notifications').select('id,group_id,type,title,body,target_type,target_id,read_at,created_at').order('created_at', { ascending: false }).range(0, notificationLimit - 1),
        supabase.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null),
      ])
      if (n.error) throw n.error
      if (u.error) throw u.error
      if (request !== notificationRequestRef.current) return
      setNotifications((n.data ?? []) as Notification[])
      setUnreadCount(u.count ?? 0)
      setHasMoreNotifications((n.data?.length ?? 0) === notificationLimit)
    } catch (reason) { if (request === notificationRequestRef.current) setError(messageOf(reason)) }
  }, [user?.id, notificationLimit])
  refreshNotificationsRef.current = refreshNotifications
  useEffect(() => { void refreshNotifications() }, [refreshNotifications])

  useEffect(() => {
    if (!supabase || !user) return
    const client = supabase
    // Realtime is best-effort; visibility/focus polling works even without publication setup.
    const ch = client.channel(`ck-notifications-${user.id}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'notifications', filter: `recipient_user_id=eq.${user.id}` }, () => { void refreshNotifications() })
      .subscribe()
    const onFocus = () => { if (document.visibilityState === 'visible') void refreshNotifications() }
    document.addEventListener('visibilitychange', onFocus)
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refreshNotifications() }, 90_000)
    return () => { document.removeEventListener('visibilitychange', onFocus); window.clearInterval(timer); void client.removeChannel(ch) }
  }, [user, refreshNotifications])

  useEffect(() => {
    if (!supabase || !user) return
    const client = supabase
    // Notification events arrive even when app is idle. Refetch on any visible group mutation.
    const channel = client.channel(`ck-ledger-${user.id}-${groupId ?? 'none'}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'expenses', ...(groupId ? { filter: `group_id=eq.${groupId}` } : {}) }, () => { void refreshGroup(); void refreshOverview(); void refreshSettlements() })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'group_members' }, () => { void refreshWorkspace(); void refreshGroup(); void refreshOverview() })
      .subscribe()
    return () => { void client.removeChannel(channel) }
  }, [user?.id, groupId, refreshGroup, refreshOverview, refreshWorkspace, refreshSettlements])
  useEffect(() => { if (!toast) return; const t = window.setTimeout(() => setToast(''), 4500); return () => window.clearTimeout(t) }, [toast])
  useEffect(() => { if (user && groupId) localStorage.setItem(`chai-khapa-group:${user.id}`, groupId) }, [user, groupId])

  const activeGroup = groups.find((g) => g.id === groupId) ?? null
  async function googleSignIn() {
    if (!supabase) return
    setError('')
    const callback = oauthReturnUrl(route.view === 'join' ? window.location.pathname : '/app')
    const { error: signInError } = await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: callback } })
    if (signInError) setError(signInError.message)
  }
  async function signOut() {
    if (!supabase) return
    const { error: signOutError } = await supabase.auth.signOut()
    if (signOutError) { setError(signOutError.message); return }
    setProfile(null); setGroups([]); setGroupId(null); setMembers([]); setExpenses([]); setBalances([]); setNotifications([]); setSettlementPeriods([]); setSettlementTransfers([]); setPaymentClaims([])
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

  async function closeMonth(group: string, month: string) {
    if (!supabase) return
    const { error: rpcError } = await supabase.rpc('close_settlement_month', { p_group_id: group, p_month: month })
    if (rpcError) throw rpcError
    await Promise.all([refreshSettlements(), refreshOverview(), refreshNotifications()])
    setToast('Month closed. Settlement instructions have been created.')
  }
  async function claimTransfer(transferId: string, paidPaisa: number) {
    if (!supabase) return
    const { error: rpcError } = await supabase.rpc('mark_transfer_paid', { p_transfer_id: transferId, p_paid_paisa: paidPaisa })
    if (rpcError) throw rpcError
    await Promise.all([refreshSettlements(), refreshOverview(), refreshNotifications()])
    setToast('Marked as paid. Awaiting the recipient’s confirmation.')
  }
  async function decideClaim(claimId: string, received: boolean) {
    if (!supabase) return
    const { error: rpcError } = await supabase.rpc('confirm_transfer_payment', { p_claim_id: claimId, p_received: received })
    if (rpcError) throw rpcError
    await Promise.all([refreshSettlements(), refreshOverview(), refreshNotifications()])
    setToast(received ? 'Payment received and balance updated.' : 'Payment rejected. The amount remains outstanding.')
  }

  if (authLoading) return <div className="auth-wait"><div className="mark">CK<span>.</span></div><Spinner /><p>Preparing your seat at the table</p></div>
  if (!user) return <Landing onSignIn={googleSignIn} loading={!hasSupabaseConfig} error={error} joinMode={route.view === 'join'} />
  if (!hasSupabaseConfig || !supabase) return <Landing onSignIn={googleSignIn} loading error="Supabase public environment variables are missing." />

  const client = supabase
  return <div className="workspace">
    <a className="skip-link" href="#content">Skip to content</a>
    <aside className={`sidebar ${mobileNav ? 'sidebar-open' : ''}`} aria-label="Main navigation">
      <div className="sidebar-top"><button className="brand-btn" onClick={() => navigate('dashboard')}><span className="brand-symbol"><Icon name="cup" size={21}/></span><span className="brand-name">chai khapa<small>THE SHARED TAB</small></span></button><button className="icon-button sidebar-close" aria-label="Close menu" onClick={() => setMobileNav(false)}><Icon name="close" /></button></div>
      <div className="sidebar-section">YOUR SPACE</div>
      <nav className="side-links">
        <NavButton icon="grid" text="Overview" active={route.view === 'dashboard'} onClick={() => navigate('dashboard')} />
        <NavButton icon="users" text="Groups" active={route.view === 'groups' || route.view === 'group'} onClick={() => navigate('groups')} />
        <NavButton icon="clock" text="Activity" active={route.view === 'activity'} onClick={() => navigate('activity')} />
        <NavButton icon="receipt" text="Settlements" active={route.view === 'dues'} onClick={() => navigate('dues')} />
        <NavButton icon="bell" text="Notifications" active={route.view === 'notifications'} badge={unreadCount} onClick={() => navigate('notifications')} />
      </nav>
      <div className="sidebar-section space-top">PREFERENCES</div>
      <nav className="side-links"><NavButton icon="settings" text="My profile" active={route.view === 'profile'} onClick={() => navigate('profile')} /></nav>
      <div className="sidebar-bottom"><div className="sidebar-tip"><Icon name="cup" size={22}/><p>Less counting.<br /><strong>More chai.</strong></p><span>✳</span></div><div className="account-mini"><Avatar name={displayName(profile)}/><span><strong>{displayName(profile)}</strong><small>{user.email ?? 'Google account'}</small></span><button className="icon-button" aria-label="Sign out" title="Sign out" onClick={() => void signOut()}><Icon name="logout" size={18}/></button></div></div>
    </aside>
    {mobileNav && <button className="nav-scrim" aria-label="Close menu" onClick={() => setMobileNav(false)} />}
    <div className="workspace-main">
      <header className="app-topbar"><div className="topbar-left"><button className="icon-button mobile-menu" aria-label="Open menu" onClick={() => setMobileNav(true)}><Icon name="menu" /></button><span className="crumb">WORKSPACE</span><span className="slash">/</span><span className="crumb-current">{route.view === 'dashboard' ? 'Overview' : route.view === 'group' ? 'Group settings' : route.view === 'dues' ? 'Settlements' : route.view === 'join' ? 'Join group' : route.view.charAt(0).toUpperCase() + route.view.slice(1)}</span></div><div className="topbar-right"><span className="online-dot" aria-hidden="true"/><span className="workspace-status">PRIVATE GROUP SPACE</span><button className="icon-button refresh-button" title="Refresh all records" aria-label="Refresh all records" onClick={() => { void refreshWorkspace(); void refreshGroup(); void refreshOverview(); void refreshNotifications() }}><Icon name="refresh" size={17}/></button>{refreshing && <span className="muted-small" aria-live="polite">Syncing</span>}{install.canPrompt && !install.installed && <button className="button button-outline install-shortcut" onClick={() => void install.install()}>Install app</button>}<button className="icon-button bell-top" aria-label={`Notifications, ${unreadCount} unread`} onClick={() => navigate('notifications')}><Icon name="bell" />{unreadCount > 0 && <span className="top-badge"/>}</button><button className="avatar-button" aria-label="Open my profile" onClick={() => navigate('profile')}><Avatar name={displayName(profile)} /></button></div></header>
      <main id="content" className="page-content">
        {error && <div className="alert error-alert" role="alert"><span>{error}</span><button aria-label="Dismiss error" onClick={() => setError('')}><Icon name="close" size={17}/></button></div>}
        {route.view !== 'join' && !profile?.name_confirmed_at && !workspaceLoading && <div className="onboarding-bar"><div className="progress-ring" style={{ '--progress': '50%' } as CSSProperties}><span>1/2</span></div><div><strong>Make it yours.</strong><p>Confirm your first and last name to finish setting up your account.</p></div><button className="button button-outline" onClick={() => navigate('profile')}>Complete profile <Icon name="arrow" size={16}/></button></div>}
        {route.view === 'join' && <JoinPage token={route.token} onJoin={async (token) => { const { data, error: joinError } = await client.rpc('join_group', { p_token: token }); if (joinError) throw joinError; await refreshWorkspace(); setGroupId(data as string); setToast('Welcome to your new group!'); navigate('dashboard') }} />}
        {route.view === 'dashboard' && <>
          <div className="page-heading compact-heading"><div><p className="micro accent">YOUR SHARED LEDGER</p><h1>Your chai circles<span className="punctuation">.</span></h1><p>Choose a group to see its balance and latest sessions.</p></div><button className="button button-copper heading-cta" onClick={() => navigate('groups')}><Icon name="plus" size={18}/> New group</button></div>
          <div className="overview-title"><h2>All groups <small>{groups.length}</small></h2><button className="subtle-link" onClick={() => navigate('dues')}>Settlements <Icon name="arrow" size={15}/></button></div>
          {workspaceLoading && !groups.length ? <LoadingPanel/> : !groups.length ? <Empty icon="users" title="Your chai story starts here" detail="Create your first group and share the invite." action={<button className="button button-copper" onClick={() => navigate('groups')}>Create group</button>}/> : <div className="overview-groups" aria-label="Your groups">{groups.map(g => {
            const summary = overview.find(x => x.id === g.id)
            const amount = summary?.net ?? 0
            return <button key={g.id} className={`overview-group-card ${groupId === g.id ? 'is-selected' : ''}`} onClick={() => { setGroupId(g.id); navigate('group', `/app/groups/${g.id}`) }}>
              <div className="overview-group-top"><span className="group-icon"><Icon name="users" size={19}/></span><span className="overview-group-name">{g.name}</span><Icon name="arrow" size={17}/></div>
              <div className={`overview-group-amount ${amount < 0 ? 'negative' : amount > 0 ? 'positive' : ''}`}>{summary ? money(amount) : (overviewLoading ? 'Updating…' : '—')}</div>
              <div className="overview-group-meta">{amount < 0 ? 'Your current share to settle' : amount > 0 ? 'Others currently owe your group share' : 'Balanced'} · {summary?.memberCount ?? '—'} members · {summary?.sessionCount ?? '—'} sessions</div>
            </button>
          })}<button className="overview-create-card" onClick={() => navigate('groups')}><Icon name="plus" size={19}/><span>Create another group</span></button></div>}
          <div className="overview-bottom">
            <section className="panel overview-quick"><SectionHead label="GET THINGS DONE" title="Quick actions"/><div className="quick-actions"><button onClick={() => navigate('record')} className="quick-action" disabled={!groups.length}><Icon name="cup"/><span className="quick-label">Record a session</span><Icon name="arrow" size={16}/></button><button onClick={() => navigate('dues')} className="quick-action"><Icon name="receipt"/><span className="quick-label">Monthly settlements</span><Icon name="arrow" size={16}/></button><button onClick={() => navigate('notifications')} className="quick-action"><Icon name="bell"/><span className="quick-label">Notifications</span><span className="quick-tail">{unreadCount > 0 && <span className="nav-badge">{unreadCount}</span>}<Icon name="arrow" size={16}/></span></button></div></section>
            <section className="panel overview-help"><SectionHead label="AT A GLANCE" title="Your outstanding balances"/><div className="overview-totals"><div><span>Across your groups · owed</span><strong className="negative">{money(overview.reduce((sum,g) => sum + Math.min(0,g.net), 0))}</strong></div><div><span>Across your groups · to receive</span><strong className="positive">{money(overview.reduce((sum,g) => sum + Math.max(0,g.net), 0))}</strong></div></div><p className="muted-small">Balances are independent in each group. These are current positions, not confirmed settlements.</p></section>
          </div>
        </>}
        {route.view === 'groups' && <GroupsPage groups={groups} groupId={groupId} userId={user.id} onChoose={(id) => { setGroupId(id); navigate('group', `/app/groups/${id}`) }} onGroupCreated={async (id) => { await refreshWorkspace(); setGroupId(id); navigate('group', `/app/groups/${id}`); setToast('Group created. Invite your colleagues!') }} />}
        {route.view === 'group' && <GroupDetailsPage key={activeGroup?.id ?? 'empty'} group={activeGroup?.id === route.token ? activeGroup : null} members={members} balances={balances} expenses={expenses} userId={user.id} loading={groupLoading} onBack={() => navigate('dashboard')} onRecord={() => navigate('record')} onActivity={() => navigate('activity')} onInviteSuccess={setToast} onChanged={async () => { await refreshWorkspace(); await refreshGroup(); await refreshOverview() }} onMembershipChanged={async () => { await refreshWorkspace(); navigate('dashboard') }} />}
        {route.view === 'dues' && <DuesPage groups={groups} overviews={overview} userId={user.id} periods={settlementPeriods} transfers={settlementTransfers} claims={paymentClaims} loading={overviewLoading || settlementLoading} onCloseMonth={closeMonth} onClaimPaid={claimTransfer} onConfirm={decideClaim} />}
        {route.view === 'record' && <RecordPage group={activeGroup} members={members} expenses={expenses} userId={user.id} onBack={() => navigate('dashboard')} onSaved={async () => { await Promise.all([refreshGroup(), refreshOverview(), refreshNotifications()]); setToast('Session recorded. Everyone’s share has been saved.'); navigate('dashboard') }} />}
        {route.view === 'activity' && <ActivityPage group={activeGroup} expenses={expenses} members={members} loading={groupLoading} onRecord={() => navigate('record')} />}
        {route.view === 'notifications' && <NotificationsPage notifications={notifications} unreadCount={unreadCount} hasMore={hasMoreNotifications} onMore={() => setNotificationLimit((x) => x + 30)} onMarkRead={markRead} onMarkAll={markAllRead} onGo={(n) => { if (n.group_id && groups.some((g) => g.id === n.group_id)) setGroupId(n.group_id); navigate(n.target_type === 'expense' ? 'activity' : n.target_type === 'settlement_transfer' ? 'dues' : 'groups') }} />}
        {route.view === 'profile' && <ProfilePage install={install} user={user} profile={profile} onSave={async () => { await refreshWorkspace(); await refreshGroup(); await refreshOverview(); setToast('Your profile has been updated.') }} onSignOut={signOut} />}
        {route.view !== 'join' && <footer className="app-footer"><span>CHAI KHAPA <span className="footer-dot">✳</span> BUILT FOR THE SHARED BREAK</span><span><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a><span>© 2026</span></span></footer>}
      </main>
    </div>
    {toast && <div className="toast" role="status"><Icon name="check" size={18}/>{toast}<button aria-label="Dismiss" onClick={() => setToast('')}><Icon name="close" size={16}/></button></div>}
    <nav className="bottom-nav" aria-label="Mobile navigation"><NavMobile icon="grid" active={route.view === 'dashboard'} label="Home" onClick={() => navigate('dashboard')}/><NavMobile icon="users" active={route.view === 'groups' || route.view === 'group'} label="Groups" onClick={() => navigate('groups')}/><button className="mobile-add" aria-label="Record chai session" onClick={() => navigate('record')}><Icon name="plus" size={24}/></button><NavMobile icon="receipt" active={route.view === 'dues'} label="Settle" onClick={() => navigate('dues')}/><NavMobile icon="bell" active={route.view === 'notifications'} label="Inbox" count={unreadCount} onClick={() => navigate('notifications')}/></nav>
  </div>
}

function messageOf(error: unknown): string { return error instanceof Error ? error.message : typeof error === 'string' ? error : 'Something went wrong. Please try again.' }
function NavButton({ icon, text, active, onClick, badge }: { icon: IconName; text: string; active: boolean; onClick: () => void; badge?: number }) { return <button className={`nav-item ${active ? 'active' : ''}`} onClick={onClick} aria-current={active ? 'page' : undefined}><Icon name={icon}/><span>{text}</span>{badge ? <span className="nav-badge">{badge > 99 ? '99+' : badge}</span> : null}</button> }
function NavMobile({ icon, label, active, count, onClick }: { icon: IconName; label: string; active: boolean; count?: number; onClick: () => void }) { return <button onClick={onClick} aria-current={active ? 'page' : undefined} className={active ? 'active' : ''}><span className="mobile-icon"><Icon name={icon}/>{count ? <i className="mobile-dot"/> : null}</span><small>{label}</small></button> }
function LoadingPanel() { return <div className="loading-panel"><Spinner /><p>Getting your latest chai records…</p></div> }
function Landing({ onSignIn, loading, error, joinMode }: { onSignIn: () => void; loading: boolean; error?: string; joinMode?: boolean }) {
  return <div className="landing"><a className="skip-link" href="#main">Skip to content</a><header className="landing-nav"><a className="landing-brand" href="/"><span className="brand-symbol"><Icon name="cup" size={21}/></span><span>CHAI KHAPA</span></a><nav aria-label="Public navigation"><a href="#how-it-works">How it works</a><a href="/privacy/">Privacy</a><a href="/terms/">Terms</a></nav></header><main id="main" className="landing-main"><p className="micro accent">MADE FOR THE EVERYDAY CHAI BREAK</p><div className="landing-grid"><div><h1>Good chai.<br/><em>Clear hisaab.</em></h1><p className="landing-lead">One person pays at the dhaba. Everyone settles their share later. The good stuff stays simple.</p><div className="landing-actions">{!loading ? <button className="button button-copper large" onClick={onSignIn}>Continue with Google <Icon name="arrow"/></button> : <div className="alert error-alert">Add your public Supabase environment variables to enable sign-in.</div>}<small>No spreadsheets. No awkward reminders.</small></div>{error && <p className="form-error" role="alert">{error}</p>}{joinMode && <p className="landing-join-note">You have a group invite. Sign in to accept it.</p>}</div><div className="landing-side"><div className="landing-visual"><div className="landing-ticket-top"><span>CHAI KHAPA / DAILY LEDGER</span><span>✳</span></div><div className="landing-visual-cup"><Icon name="cup" size={68}/></div><div className="ticket-bottom"><span>THE TAB <small>EVERYONE'S COVERED</small></span><strong>Rs. 350.00</strong></div><div className="ticket-split">5 colleagues <span>Rs. 70 each</span></div></div><p className="landing-quote">“Tu chai pee, hisaab app mein hai.”</p></div></div><section id="how-it-works" className="landing-how"><p className="micro">THE PROCESS / THREE SMALL STEPS</p><div className="landing-steps"><div><span>01</span><h2>Someone pays.</h2><p>One colleague handles the cash at the dhaba.</p></div><div><span>02</span><h2>Log the bill.</h2><p>Enter the amount and tick who was there.</p></div><div><span>03</span><h2>Settle later.</h2><p>Everyone can see exactly what they've paid and consumed.</p></div></div></section></main><footer className="landing-footer"><span>CHAI KHAPA · GOOD CHAI, CLEAR HISAAB.</span><div><a href="/privacy/">Privacy Policy</a><a href="/terms/">Terms of Service</a></div><span>© 2026</span></footer></div>
}

function GroupsPage({ groups, groupId, userId, onChoose, onGroupCreated }: { groups: Group[]; groupId: string | null; userId: string; onChoose: (id: string) => void; onGroupCreated: (id: string) => Promise<void> }) {
  const [name, setName] = useState('')
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState('')
  async function createGroup(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!supabase) return
    setCreating(true); setError('')
    try {
      const { data, error: rpcError } = await supabase.rpc('create_group', { p_name: name.trim() })
      if (rpcError) throw rpcError
      await onGroupCreated(data as string)
      setName('')
    } catch (reason) { setError(messageOf(reason)) }
    finally { setCreating(false) }
  }
  return <>
    <div className="page-heading short"><div><p className="micro accent">YOUR CIRCLES</p><h1>Chai groups<span className="punctuation">.</span></h1><p>Your groups and all their members, invitations, and settings in one place.</p></div></div>
    <div className="two-col group-list-layout">
      <section className="panel"><SectionHead label="YOUR GROUPS" title={`${groups.length} ${groups.length === 1 ? 'group' : 'groups'}`}/>
        {groups.length ? <div className="groups-list">{groups.map(g => <button key={g.id} className={`group-card group-card-button ${groupId === g.id ? 'selected' : ''}`} onClick={() => onChoose(g.id)}>
          <span className="group-icon"><Icon name="users"/></span><span className="group-card-content"><strong>{g.name}</strong><small>{g.owner_user_id === userId ? 'OWNER' : 'MEMBER'} · {g.archived_at ? 'ARCHIVED' : 'ACTIVE'} · MANAGE GROUP</small></span><span className="group-card-arrow"><Icon name="arrow" size={18}/></span>
        </button>)}</div> : <Empty icon="users" title="No groups yet" detail="Make a home for your chai crew."/>}
      </section>
      <section className="panel create-panel"><SectionHead label="START SOMETHING" title="Create a new group"/><p className="panel-description">Set up a new shared ledger and invite your colleagues from its management page.</p>
        <form onSubmit={(e) => void createGroup(e)}><label className="field-label" htmlFor="group-name">GROUP NAME</label><input id="group-name" placeholder="e.g. Office Chai Gang" maxLength={80} minLength={2} required value={name} onChange={e => setName(e.target.value)} />
          <button className="button button-copper form-submit" disabled={creating || name.trim().length < 2}>{creating ? <Spinner/> : <Icon name="plus" size={18}/>} Create group</button>
        </form>{error && <p className="form-error" role="alert">{error}</p>}
      </section>
    </div>
  </>
}

function JoinPage({ token, onJoin }: { token: string | null; onJoin: (token: string) => Promise<void> }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  async function accept() { if (!token) return; setBusy(true); setError(''); try { await onJoin(token) } catch (reason) { setError(messageOf(reason)) } finally { setBusy(false) } }
  return <div className="join-wrap"><div className="join-card"><div className="empty-symbol"><Icon name="users" size={30}/></div><p className="micro accent">A SEAT AT THE TABLE</p><h1>You're invited<span className="punctuation">.</span></h1><p>Someone has shared a Chai Khapa group invitation with you. Join to see sessions and contribute to the group's ledger.</p>{token ? <button className="button button-copper" onClick={() => void accept()} disabled={busy}>{busy ? <Spinner/> : <Icon name="check"/>} Accept invitation</button> : <p className="form-error">This invitation URL is invalid.</p>}{error && <p className="form-error" role="alert">{error}</p>}</div></div>
}

function GroupDetailsPage({ group, members, balances, expenses, userId, loading, onBack, onRecord, onActivity, onInviteSuccess, onChanged, onMembershipChanged }: {
  group: Group | null; members: Member[]; balances: Balance[]; expenses: Expense[]; userId: string; loading: boolean;
  onBack: () => void; onRecord: () => void; onActivity: () => void; onInviteSuccess: (text: string) => void; onChanged: () => Promise<void>; onMembershipChanged: () => Promise<void>
}) {
  const [tab, setTab] = useState<'overview' | 'people' | 'settings'>('overview')
  const [name, setName] = useState(group?.name ?? '')
  const [inviteLink, setInviteLink] = useState('')
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [confirm, setConfirm] = useState('')
  const [nextOwner, setNextOwner] = useState('')
  useEffect(() => { setName(group?.name ?? ''); setInviteLink(''); setConfirm('') }, [group?.id, group?.name])
  if (!group) return <Empty icon="users" title="Group not found" detail="You may have left this group or used an outdated link." action={<button className="button button-outline" onClick={onBack}>Back to groups</button>} />
  const owned = group.owner_user_id === userId
  const archived = Boolean((group as Group & { archived_at?: string | null }).archived_at)
  const action = async (fn: () => Promise<void>) => { setBusy(true); setError(''); try { await fn() } catch(e) { setError(messageOf(e)) } finally { setBusy(false) } }
  const call = async (fn: string, args: Record<string, unknown>) => {
    if (!supabase) throw new Error('Supabase is unavailable')
    // New RPCs are installed by migration 20261101010000_group_management.sql.
    const { error: failure } = await supabase.rpc(fn as 'rename_group', args)
    if (failure) throw failure
  }
  const createInvite = () => void action(async () => {
    if (!supabase) return
    const { data, error } = await supabase.rpc('create_group_invite', { p_group_id: group.id, p_max_uses: 25, p_expiry_hours: 168 })
    if (error) throw error
    const link = invitationUrl((data as { token: string }).token)
    setInviteLink(link)
    try { await navigator.clipboard.writeText(link); setCopied(true); onInviteSuccess('Invite created and copied') }
    catch { setCopied(false); onInviteSuccess('Invite ready. Copy it using the button below.') }
  })
  const copy = async () => { try { await navigator.clipboard.writeText(inviteLink); setCopied(true); onInviteSuccess('Invite copied') } catch { setError('Clipboard access is unavailable. Select the link text to copy.') } }
  return <>
    <div className="page-heading short"><div><p className="micro accent"><button className="text-back" onClick={onBack}>← ALL GROUPS</button> / GROUP MANAGEMENT</p><h1>{group.name}<span className="punctuation">.</span></h1><p>{archived ? 'Archived · read-only history preserved' : `${members.length} members · ${expenses.length} recent sessions`}</p></div>{!archived && <button className="button button-copper heading-cta" onClick={onRecord}><Icon name="plus"/> Record session</button>}</div>
    <div className="group-detail-layout">
      <div className="group-detail-main"><div className="tabs" role="tablist" aria-label="Group management"><button role="tab" aria-selected={tab === 'overview'} className={tab === 'overview' ? 'active' : ''} onClick={() => setTab('overview')}>Overview</button><button role="tab" aria-selected={tab === 'people'} className={tab === 'people' ? 'active' : ''} onClick={() => setTab('people')}>People & balances</button><button role="tab" aria-selected={tab === 'settings'} className={tab === 'settings' ? 'active' : ''} onClick={() => setTab('settings')}>Settings & access</button></div>
        {tab === 'overview' ? <section className="panel"><SectionHead label="CURRENT GROUP" title="Group snapshot" aside={<button className="subtle-link" onClick={onActivity}>All sessions <Icon name="arrow" size={15}/></button>}/>
          <div className="group-stats"><div><span>Your current net position</span><strong className={(Number(balances.find(b=>b.user_id===userId)?.net_paisa ?? 0) < 0 ? 'negative' : 'positive')}>{money(balances.find(b=>b.user_id===userId)?.net_paisa ?? 0)}</strong></div><div><span>Active members</span><strong>{members.length}</strong></div><div><span>Recent sessions</span><strong>{expenses.length}</strong></div></div>
          <p className="micro">LATEST GROUP SESSIONS</p>{expenses.length ? <div className="activity-list">{expenses.slice(0,4).map(e=><button key={e.id} className="expense-row" onClick={onActivity}><span className="expense-icon"><Icon name="cup"/></span><span className="expense-info"><strong>{e.description || 'Chai session'}</strong><small>{relativeDate(e.occurred_at)}</small></span><span className="expense-end"><strong>{money(e.amount_paisa)}</strong><small>{e.shares.length} attendees</small></span></button>)}</div> : <Empty icon="cup" title="No chai sessions yet" detail="Record a session to begin this group's ledger." />}
        </section> : tab === 'people' ? <section className="panel"><SectionHead label="MEMBERS" title="Everyone at the table" aside={<span className="people-count">{members.length} active</span>}/>{loading ? <LoadingPanel /> : <div className="member-management-list">{members.map(m => { const balance = balances.find(b => b.user_id === m.user_id); return <div key={m.user_id} className="member-management-row"><Avatar name={m.name}/><div><strong>{m.name}{m.user_id === userId && <small> · You</small>}</strong><span>{m.role === 'owner' ? 'Owner' : 'Member'}</span></div><b className={(Number(balance?.net_paisa ?? 0) < 0 ? 'negative' : 'positive')}>{money(balance?.net_paisa ?? 0)}</b></div> })}</div>}<p className="panel-bottom-note">Net positions only. Final transfers and confirmations are a separate settlement step.</p></section> : <section className="panel"><SectionHead label="PREFERENCES" title="Group settings"/>
          <label className="field-label" htmlFor="rename-group">GROUP NAME</label><div className="manage-inline"><input id="rename-group" value={name} maxLength={80} disabled={!owned || busy} onChange={e=>setName(e.target.value)} /><button className="button button-outline" disabled={!owned || busy || name.trim() === group.name || name.trim().length < 2} onClick={() => void action(async () => { await call('rename_group', { p_group_id: group.id, p_name: name.trim() }); await onChanged(); onInviteSuccess('Group renamed') })}>Save</button></div>
          {!owned && <p className="muted-small">Only the group owner can change settings.</p>}
          {owned && <><div className="divider"/><label className="field-label" htmlFor="owner-choice">TRANSFER OWNERSHIP</label><p className="muted-small">Transfer to an active member before leaving. Your role becomes member.</p><div className="manage-inline"><select id="owner-choice" value={nextOwner} onChange={e => setNextOwner(e.target.value)}><option value="">Choose member</option>{members.filter(m=>m.user_id!==userId).map(m=><option value={m.user_id} key={m.user_id}>{m.name}</option>)}</select><button disabled={!nextOwner || busy} className="button button-outline" onClick={() => { if (window.confirm('Transfer group ownership? The new owner can manage this group.')) void action(async () => { await call('transfer_group_ownership', { p_group_id: group.id, p_new_owner_user_id: nextOwner }); await onChanged(); onInviteSuccess('Ownership transferred') }) }}>Transfer</button></div></>}
          {owned && <><div className="divider"/><p className="micro">ARCHIVING</p><p className="muted-small">Archived groups keep their ledger but stop new sessions and invitations. You can reopen them.</p><button className="button button-outline" disabled={busy} onClick={() => { if (window.confirm(archived ? 'Reopen this group?' : 'Archive this group? No new expenses can be recorded while archived.')) void action(async()=>{ await call('set_group_archived', { p_group_id: group.id, p_archived: !archived }); await onChanged(); onInviteSuccess(archived ? 'Group reopened' : 'Group archived') }) }}>{archived ? 'Reopen group' : 'Archive group'}</button></>}
        </section>}
      </div>
      <aside className="group-detail-aside"><section className="panel"><SectionHead label="SHARE THE TABLE" title="Invite colleagues"/><p className="muted-small">{owned ? 'Create a secure invitation for this group. The token is shown once.' : 'Ask the group owner for an invitation link.'}</p>{owned && !archived && <button className="button button-copper" disabled={busy} onClick={createInvite}><Icon name="link"/> Create & copy invite</button>}{inviteLink && <div className="invite-box invite-box-inline"><label className="field-label" htmlFor="group-invite">INVITATION URL</label><input id="group-invite" readOnly value={inviteLink} onFocus={e=>e.currentTarget.select()}/><button className="button button-outline" onClick={() => void copy()}><Icon name="copy"/> {copied ? 'Copied · copy again' : 'Copy invitation'}</button><p className="muted-small">{['localhost', '127.0.0.1'].includes(new URL(inviteLink).hostname) ? 'This is a local testing URL. Open the deployed app to invite colleagues remotely.' : 'Invite expires in 7 days (up to 25 uses).'}</p></div>}</section>
        <section className="panel danger-panel"><SectionHead label="MEMBERSHIP" title={owned ? 'Delete empty group' : 'Leave this group'}/><p className="muted-small">{owned ? 'Only groups with no recorded expenses can be deleted. Financial history is protected.' : 'You can leave when your current net balance is zero.'}</p><button className="button button-outline danger-outline" disabled={busy} onClick={()=>setConfirm(owned ? 'delete' : 'leave')}>{owned ? 'Delete empty group' : 'Leave group'}</button>{confirm && <div className="confirm-box" role="group" aria-label="Confirm group action"><p>Are you sure? {owned ? 'This empty group will be deleted.' : 'You will lose access to this group.'}</p><button className="button button-outline" onClick={() => setConfirm('')}>Cancel</button><button className="button button-copper" onClick={() => void action(async () => { await call(owned ? 'delete_empty_group' : 'leave_group', { p_group_id: group.id }); await onMembershipChanged(); onInviteSuccess(owned ? 'Group deleted' : 'You left the group') })}>Confirm</button></div>}</section>{error && <p className="form-error" role="alert">{error}</p>}
      </aside>
    </div>
  </>
}

function DuesPage({ groups, overviews, userId, periods, transfers, claims, loading, onCloseMonth, onClaimPaid, onConfirm }: {
  groups: Group[]; overviews: GroupOverview[]; userId: string; periods: SettlementPeriod[];
  transfers: SettlementTransfer[]; claims: PaymentClaim[]; loading: boolean;
  onCloseMonth: (groupId: string, month: string) => Promise<void>;
  onClaimPaid: (transferId: string, amount: number) => Promise<void>;
  onConfirm: (claimId: string, received: boolean) => Promise<void>
}) {
  const [busy, setBusy] = useState<string | null>(null)
  const [actionError, setActionError] = useState('')
  const [payChoice, setPayChoice] = useState<Record<string, 'exact' | 'round'>>({})
  const previousMonth = useMemo(() => {
    const today = new Date()
    const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Karachi', year: 'numeric', month: '2-digit' }).formatToParts(today)
    const year = Number(parts.find(p => p.type === 'year')?.value ?? today.getUTCFullYear())
    const month = Number(parts.find(p => p.type === 'month')?.value ?? today.getUTCMonth() + 1)
    return new Date(Date.UTC(year, month - 2, 1)).toISOString().slice(0,10)
  }, [])
  function getName(groupId: string, id: string) {
    return displayName(overviews.find(g => g.id === groupId)?.balances.find(b => b.user_id === id))
  }
  async function run(key: string, action: () => Promise<void>) {
    setActionError(''); setBusy(key)
    try { await action() } catch (reason) { setActionError(messageOf(reason)) } finally { setBusy(null) }
  }
  const suggestions = overviews.flatMap(g => computeTransfers(g.balances).filter(t => t.from === userId).map(t => ({ ...t, groupId: g.id, groupName: g.name, recipient: getName(g.id, t.to) })))
  const relevant = transfers.filter(t => t.debtor_user_id === userId || t.creditor_user_id === userId)
  const pending = relevant.filter(t => t.status !== 'confirmed')
  const total = pending.filter(t => t.debtor_user_id === userId).reduce((sum, t) => sum + Number(t.amount_paisa), 0)
  const openMonths = groups.filter(g => g.owner_user_id === userId && !periods.some(p => p.group_id === g.id && p.period_month === previousMonth))
  return <>
    <div className="page-heading short"><div><p className="micro accent">SETTLE WITH CONFIDENCE</p><h1>Monthly settlements<span className="punctuation">.</span></h1><p>Track what you owe, confirm money received, and keep every month accountable.</p></div></div>
    <div className="settlement-summary"><div><p className="micro">YOU STILL OWE · CONFIRMATION PENDING INCLUDED</p><strong>{money(total)}</strong><p>Only confirmed receipts clear a settlement.</p></div><div><p className="micro">HOW IT WORKS</p><p>At month-end the group owner closes the month. Pay outside Chai Khapa, mark it paid here, and the recipient confirms the receipt. No payments are processed by this app.</p></div></div>
    {actionError && <div role="alert" className="alert error-alert">{actionError}</div>}
    {openMonths.length > 0 && <section className="panel settlement-close"><SectionHead label="GROUP OWNER CONTROLS" title="Close the completed month"/><p className="muted-small">Close {new Date(`${previousMonth}T12:00:00Z`).toLocaleDateString('en-PK', { month: 'long', year: 'numeric', timeZone: 'UTC' })} after the month ends in Pakistan time. Existing session entries for the closed month will be locked.</p><div className="settlement-close-actions">{openMonths.map(g => <button key={g.id} className="button button-outline" disabled={busy !== null} onClick={() => { if (window.confirm(`Close ${previousMonth} for ${g.name}? This locks the month's records.`)) void run(`close:${g.id}`, () => onCloseMonth(g.id, previousMonth)) }}>{busy === `close:${g.id}` ? <Spinner/> : <Icon name="check" size={16}/>} Close {g.name}</button>)}</div></section>}
    <section className="panel settlement-ledger"><SectionHead label="PERIOD LEDGER" title="Your settlement instructions" aside={<span className="people-count">{pending.length} pending</span>}/>
      {loading ? <LoadingPanel/> : !periods.length ? <Empty icon="receipt" title="No closed months yet" detail="An owner can close each completed month. Until then, you can review live provisional balances below."/> : periods.map(p => {
        const rows = relevant.filter(t => t.period_id === p.id)
        const groupName = groups.find(g => g.id === p.group_id)?.name ?? 'Group'
        if (!rows.length) return null
        return <div className="settlement-period" key={p.id}><div className="settlement-period-head"><h3>{new Date(`${p.period_month}T12:00:00Z`).toLocaleDateString('en-PK',{month:'long',year:'numeric',timeZone:'UTC'})}</h3><span>{groupName}</span></div>{rows.map(t => {
          const debtor = t.debtor_user_id === userId
          const otherId = debtor ? t.creditor_user_id : t.debtor_user_id
          const due = Number(t.amount_paisa)
          const rounded = Math.ceil(due / 100) * 100
          const selectedPaid = payChoice[t.id] === 'exact' ? due : rounded
          const claim = claims.find(c => c.transfer_id === t.id && c.status === 'pending')
          return <div className="settlement-transfer" key={t.id}><div className="settlement-transfer-info"><span className="micro">{debtor ? 'PAY TO' : 'RECEIVE FROM'}</span><h4>{getName(t.group_id, otherId)}</h4><strong>{money(due)}</strong><span className={`settlement-status status-${t.status}`}>{t.status === 'confirmed' ? 'Confirmed & settled' : t.status === 'awaiting_confirmation' ? 'Awaiting receipt confirmation' : 'Payment outstanding'}</span></div>
          {debtor && t.status === 'unpaid' && <div className="settlement-action"><label className="field-label" htmlFor={`pay-method-${t.id}`}>AMOUNT YOU ACTUALLY PAID</label><select id={`pay-method-${t.id}`} value={payChoice[t.id] ?? 'round'} onChange={e => setPayChoice(v => ({...v,[t.id]: e.target.value as 'exact'|'round'}))}><option value="round">Rounded transfer · {money(rounded)}</option><option value="exact">Exact amount · {money(due)}</option></select>{rounded > due && <p className="muted-small">Rounded amount includes a voluntary {money(rounded-due)} extra. Only the exact debt is cleared.</p>}<button className="button button-copper" disabled={busy !== null} onClick={() => { if(window.confirm(`Have you ALREADY sent ${money(selectedPaid)} to ${getName(t.group_id,otherId)} outside Chai Khapa?`)) void run(t.id,()=>onClaimPaid(t.id,selectedPaid)) }}>{busy===t.id?<Spinner/>:<Icon name="check" size={16}/>} Mark as paid</button></div>}
          {!debtor && t.status === 'awaiting_confirmation' && claim && <div className="settlement-action"><p className="muted-small">They reported paying {money(claim.actual_paid_paisa)}. Did you receive it?</p><div className="settlement-buttons"><button className="button button-copper" disabled={busy !== null} onClick={() => void run(claim.id,()=>onConfirm(claim.id,true))}>Confirm received</button><button className="button button-outline" disabled={busy !== null} onClick={() => void run(claim.id,()=>onConfirm(claim.id,false))}>Not received</button></div></div>}
          </div>
        })}</div>
      })}
      {!loading && periods.length>0 && relevant.length===0 && <Empty icon="check" title="Nothing to settle in closed months" detail="Your monthly expense share is already balanced."/>}
    </section>
    <section className="panel settlement-preview"><SectionHead label="LIVE BALANCES" title="Before the next month-end"/><p className="muted-small">These are provisional suggestions across all sessions and confirmed receipts. They can change as more chai is recorded; they are not payment requests.</p>{suggestions.length ? <div className="due-list">{suggestions.map(s => <div className="due-row" key={`${s.groupId}:${s.to}:${s.from}`}><div><span className="micro">{s.groupName}</span><h2>{s.recipient}</h2><p>Current suggested transfer</p></div><strong>{money(s.amountPaisa)}</strong></div>)}</div> : <p className="muted-small">No additional transfers suggested at the moment.</p>}</section>
  </>
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
  if (group?.archived_at) return <Empty icon="users" title="Group archived" detail="Reopen this group in Settings before recording more sessions." action={<button className="button button-outline" onClick={onBack}>Back to overview</button>}/>
  if (!group) return <><div className="page-heading short"><div><h1>Record chai<span className="punctuation">.</span></h1></div></div><Empty icon="users" title="Choose a group first" detail="Create or join a group before recording your first session." action={<button className="button button-outline" onClick={onBack}>Back to overview</button>}/></>
  return <><div className="page-heading short"><div><p className="micro accent">NEW ENTRY / {group.name.toUpperCase()}</p><h1>Record chai<span className="punctuation">.</span></h1><p>Amount first. Check who's here. Done.</p></div></div><form className="record-layout" onSubmit={(e) => void save(e)}><section className="panel record-main"><SectionHead label="01 / THE BILL" title="How much was it?"/><label className="field-label" htmlFor="amount">TOTAL AMOUNT (PKR)</label><div className="amount-input"><span>Rs.</span><input id="amount" autoFocus inputMode="decimal" pattern="[0-9]+(\.[0-9]{1,2})?" placeholder="350" value={amount} onChange={(e) => setAmount(e.target.value)} required aria-describedby="amount-help" /></div><p id="amount-help" className="field-help">Enter rupees. You can include up to 2 decimal places.</p><div className="divider"/><SectionHead label="02 / THE TABLE" title="Who was there?" aside={<span className="people-count">{chosen.length} selected</span>}/><p className="panel-description">Attendees are preselected from the previous session. Make any changes you need. You're always included as the payer.</p>{members.length ? <div className="attendee-grid">{members.map((m) => <label key={m.user_id} className={`attendee ${chosen.includes(m.user_id) ? 'checked' : ''}`}><input type="checkbox" checked={chosen.includes(m.user_id)} disabled={m.user_id === userId} onChange={() => toggle(m.user_id)}/><Avatar name={m.name}/><span>{m.name}{m.user_id === userId ? <small>YOU · PAID</small> : null}</span><span className="custom-check"><Icon name="check" size={14}/></span></label>)}</div> : <p className="muted-small">Loading members…</p>}<div className="divider"/><label className="field-label" htmlFor="description">SESSION NOTE <span className="optional">OPTIONAL</span></label><input id="description" placeholder="e.g. Afternoon chai" maxLength={240} value={description} onChange={(e) => setDescription(e.target.value)} />{error && <p className="form-error" role="alert">{error}</p>}</section><aside className="record-summary"><div className="summary-top"><span className="micro">SESSION SUMMARY</span><Icon name="receipt" size={22}/></div><div className="summary-amount">{amountPaisa ? money(amountPaisa) : 'Rs. —'}</div><p className="muted-small">{chosen.length} {chosen.length === 1 ? 'person' : 'people'} · paid by you · equally split</p><div className="summary-splits">{chosen.map((id) => <div key={id}><span>{members.find((m) => m.user_id === id)?.name ?? 'Colleague'}</span><strong>{amountPaisa ? money(splits[id] ?? 0) : '—'}</strong></div>)}</div><button type="submit" className="button button-copper full" disabled={!amountPaisa || !chosen.length || busy}>{busy ? <Spinner/> : <Icon name="check" size={18}/>} {busy ? 'Saving session…' : 'Save this session'}</button><button type="button" className="button button-text full" onClick={onBack}>Cancel</button><p className="summary-note">The bill, individual shares, and notifications are saved together. No one needs to pay right now.</p></aside></form></>
}

function ActivityPage({ group, expenses, members, loading, onRecord }: { group: Group | null; expenses: Expense[]; members: Member[]; loading: boolean; onRecord: () => void }) {
  const [expanded, setExpanded] = useState<string | null>(null)
  const memberName = (id: string) => members.find((m) => m.user_id === id)?.name ?? 'Colleague'
  return <><div className="page-heading short"><div><p className="micro accent">EVERY CUP, ACCOUNTED FOR</p><h1>Session history<span className="punctuation">.</span></h1><p>{group ? `The shared ledger for ${group.name}.` : 'Select a group to see its sessions.'}</p></div><button className="button button-copper heading-cta" onClick={onRecord} disabled={!group || Boolean(group.archived_at)}><Icon name="plus"/> Record session</button></div><div className="panel activity-panel"><SectionHead label="THE RECORD" title="All sessions" aside={<span className="people-count">Latest {expenses.length} records</span>}/>{loading ? <LoadingPanel/> : !group ? <Empty icon="users" title="No group selected" detail="Choose or create a group to view the ledger."/> : expenses.length ? <div className="activity-list full-list">{expenses.map((expense) => <div className="activity-entry" key={expense.id}><button className="expense-row" onClick={() => setExpanded(expanded === expense.id ? null : expense.id)} aria-expanded={expanded === expense.id}><span className="expense-icon"><Icon name="cup"/></span><span className="expense-info"><strong>{expense.description || 'Chai session'}</strong><small>{memberName(expense.paid_by_user_id)} paid <span>·</span> {relativeDate(expense.occurred_at)}</small></span><span className="expense-end"><strong>{money(expense.amount_paisa)}</strong><small>{expense.shares.length} people <Icon name="chevron" size={14}/></small></span></button>{expanded === expense.id && <div className="activity-shares"><p className="micro">INDIVIDUAL SHARES</p>{expense.shares.map((share) => <div key={share.user_id}><span>{memberName(share.user_id)}</span><strong>{money(share.share_paisa)}</strong></div>)}</div>}</div>)}</div> : <Empty icon="receipt" title="No sessions recorded" detail="As soon as someone adds a bill, it will show up here." action={<button className="button button-copper" onClick={onRecord}>Record a session</button>}/>}<p className="panel-bottom-note">Showing up to 150 recent sessions in this release. Full history pagination will follow.</p></div></>
}

function NotificationsPage({ notifications, unreadCount, hasMore, onMore, onMarkRead, onMarkAll, onGo }: { notifications: Notification[]; unreadCount: number; hasMore: boolean; onMore: () => void; onMarkRead: (id: string) => Promise<void>; onMarkAll: () => Promise<void>; onGo: (n: Notification) => void }) {
  return <><div className="page-heading short"><div><p className="micro accent">WHAT'S NEW</p><h1>Your inbox<span className="punctuation">.</span></h1><p>Chai updates, group activity, and things that need your attention.</p></div></div><section className="panel notification-panel"><SectionHead label="NOTIFICATIONS" title={unreadCount ? `${unreadCount} unread` : 'All caught up'} aside={unreadCount ? <button className="subtle-link" onClick={() => void onMarkAll()}><Icon name="check" size={15}/> Mark all as read</button> : undefined}/>{notifications.length ? <div className="notification-list">{notifications.map((n) => <div key={n.id} className={`notification-item ${!n.read_at ? 'unread' : ''}`}><div className="notification-symbol"><Icon name={n.type === 'expense_created' ? 'cup' : 'users'} size={20}/></div><button className="notification-content" onClick={() => { void onMarkRead(n.id); onGo(n) }}><strong>{n.title}</strong><p>{n.body}</p><small>{relativeDate(n.created_at)}</small></button><div className="notification-actions">{!n.read_at && <button className="read-btn" title="Mark as read" aria-label={`Mark ${n.title} as read`} onClick={() => void onMarkRead(n.id)}><Icon name="check" size={16}/></button>}{!n.read_at && <span className="unread-pip" aria-hidden="true"/>}</div></div>)}</div> : <Empty icon="bell" title="It's quiet in here" detail="When someone records a session or joins your group, you'll see it here."/>}{hasMore && <button className="button button-outline load-more" onClick={onMore}>Load more notifications <Icon name="arrow" size={15}/></button>}</section></>
}

function ProfilePage({ install, user, profile, onSave, onSignOut }: { install: ReturnType<typeof useInstallApp>; user: User; profile: Profile | null; onSave: () => Promise<void>; onSignOut: () => Promise<void> }) {
  const metadataName = String(user.user_metadata?.full_name ?? user.user_metadata?.name ?? '').trim().split(/\s+/)
  const [first, setFirst] = useState(profile?.first_name || metadataName[0] || '')
  const [last, setLast] = useState(profile?.last_name || metadataName.slice(1).join(' ') || '')
  const [busy, setBusy] = useState(false), [error, setError] = useState('')
  useEffect(() => { if (profile?.name_confirmed_at) { setFirst(profile.first_name || ''); setLast(profile.last_name || '') } }, [profile])
  async function save(e: FormEvent<HTMLFormElement>) { e.preventDefault(); if (!supabase) return; setBusy(true); setError(''); try { const { error: rpcError } = await supabase.rpc('complete_profile', { p_first_name: first.trim(), p_last_name: last.trim() }); if (rpcError) throw rpcError; await onSave() } catch (reason) { setError(messageOf(reason)) } finally { setBusy(false) } }
  return <><div className="page-heading short"><div><p className="micro accent">ACCOUNT DETAILS</p><h1>Your profile<span className="punctuation">.</span></h1><p>The name your chai group will recognize.</p></div></div><div className="two-col profile-grid"><section className="panel"><SectionHead label="YOUR DETAILS" title="The basics"/><form onSubmit={(e) => void save(e)}><div className="profile-avatar-row"><Avatar name={displayName(profile) === 'Colleague' ? `${first} ${last}` : displayName(profile)} size="md"/><div><strong>{profile?.name_confirmed_at ? 'Profile confirmed' : 'One last introduction'}</strong><p className="muted-small">These names appear in your group ledger.</p></div></div><div className="input-grid"><div><label className="field-label" htmlFor="first-name">FIRST NAME</label><input id="first-name" maxLength={80} required value={first} onChange={(e) => setFirst(e.target.value)}/></div><div><label className="field-label" htmlFor="last-name">LAST NAME</label><input id="last-name" maxLength={80} required value={last} onChange={(e) => setLast(e.target.value)}/></div></div><label className="field-label" htmlFor="account-email">GOOGLE ACCOUNT</label><input id="account-email" readOnly value={user.email ?? ''} /><p className="field-help">Your email comes from Google and isn't editable here.</p>{error && <p className="form-error" role="alert">{error}</p>}<button className="button button-copper form-submit" type="submit" disabled={busy || !first.trim() || !last.trim()}>{busy ? <Spinner/> : <Icon name="check" size={17}/>} {profile?.name_confirmed_at ? 'Save changes' : 'Confirm my name'}</button></form></section><aside className="panel profile-side"><SectionHead label="YOUR ACCOUNT" title={profile?.name_confirmed_at ? 'Profile complete' : 'Getting started'}/><div className="setup-progress"><span className="progress-ring large-ring" style={{ '--progress': profile?.name_confirmed_at ? '100%' : '50%' } as CSSProperties}><strong>{profile?.name_confirmed_at ? '2/2' : '1/2'}</strong></span><div><strong>{profile?.name_confirmed_at ? 'All set.' : 'Nearly there.'}</strong><p className="muted-small">{profile?.name_confirmed_at ? 'Your Google account and display name are ready. You can update your name anytime.' : 'Confirm your first and last name to finish the essentials.'}</p></div></div><div className="setup-step"><Icon name="check" size={18}/> Google account connected</div><div className={`setup-step ${profile?.name_confirmed_at ? '' : 'pending'}`}><Icon name={profile?.name_confirmed_at ? 'check' : 'clock'} size={18}/> Name confirmed</div><p className="muted-small setup-footer">Raast and wallet details are optional and will be added later.</p><div className="divider"/><p className="micro">INSTALL CHAI KHAPA</p><p className="muted-small">{install.installed ? 'App is installed.' : install.instructions}</p>{!install.installed && install.canPrompt && <button type="button" className="button button-outline" onClick={() => void install.install()}><Icon name="plus" size={17}/> Install app</button>}<button className="button button-outline" onClick={() => void onSignOut()}><Icon name="logout" size={17}/> Sign out</button></aside></div></>
}
