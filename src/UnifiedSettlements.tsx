import { useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from './lib/supabase'
import { formatPkr, rupeesToPaisa } from './lib/finance'
import { describeAppError } from './lib/errors'
import { remainingPaisa, wholeRupeeRoundUp, totalOutstanding } from './lib/settlementAmounts'
import './phase39-unified.css'

export type CKGroup = { id: string; name: string; owner_user_id: string; timezone: string }
export type CKOverview = { id: string; name: string; balances: { user_id: string; first_name: string | null; last_name: string | null }[] }
export type CKPeriod = { id: string; group_id: string; period_month: string; closed_at: string }
export type CKPendingMonth = { group_id: string; group_name: string; period_month: string; session_count: number; total_paisa: number; can_close: boolean }
export type CKTransfer = {
  id: string; period_id: string | null; origin_month: string | null; source: 'early'|'month_end';
  group_id: string; debtor_user_id: string; creditor_user_id: string; amount_paisa: number;
  applied_paisa: number; status: 'unpaid'|'awaiting_confirmation'|'confirmed'; confirmed_at: string|null
}
export type CKClaim = { id: string; transfer_id: string; applied_paisa: number; actual_paid_paisa: number; status: 'pending'|'confirmed'|'rejected'; created_at: string }
export type CKSuggestion = { group_id: string; debtor_user_id: string; creditor_user_id: string; amount_paisa: number }
export type CKSession = { expense_id: string; occurred_at: string; description: string | null; bill_paisa: number; my_share_paisa: number; my_contribution_paisa: number }

type Props = {
  groups: CKGroup[]; overviews: CKOverview[]; userId: string; periods: CKPeriod[];
  pendingMonths: CKPendingMonth[]; transfers: CKTransfer[]; claims: CKClaim[];
  openSuggestions: CKSuggestion[]; loading: boolean;
  onCloseMonth: (groupId: string, month: string) => Promise<void>;
  onEarlyClaim: (groupId: string, rows: {recipient: string;amountPaisa:number}[], requestId: string, roundUp: boolean) => Promise<void>;
  onBatchClaim: (ids: string[], amounts: number[], requestId: string, roundUp: boolean) => Promise<void>;
  onConfirm: (claimId: string, received: boolean) => Promise<void>;
}

// PKT is the accounting timezone for Chai Khapa groups in V1.
export function monthInKarachi(date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone:'Asia/Karachi',year:'numeric',month:'2-digit'}).formatToParts(date)
  return `${parts.find(p=>p.type==='year')?.value}-${parts.find(p=>p.type==='month')?.value}-01`
}
function monthLabel(month: string) {
  return new Date(`${month}T12:00:00Z`).toLocaleDateString('en-GB',{timeZone:'UTC',month:'long',year:'numeric'})
}
const money = formatPkr
function safeNumber(paisa: number | string) { return Number(paisa) || 0 }
function dueOf(t: CKTransfer) { return remainingPaisa(safeNumber(t.amount_paisa),safeNumber(t.applied_paisa)) }
function groupMonthKey(groupId: string, month: string) {return `${month}|${groupId}`}
function paymentStatus(t: CKTransfer) {
  return t.status==='confirmed' ? 'Paid and confirmed' : t.status==='awaiting_confirmation' ? 'Awaiting confirmation' :
    t.applied_paisa>0 ? 'Partially settled' : 'Unpaid'
}

export default function UnifiedSettlements({ groups, overviews, userId, periods, pendingMonths, transfers, claims, openSuggestions, loading, onCloseMonth, onEarlyClaim, onBatchClaim, onConfirm }: Props) {
  const currentMonth=monthInKarachi()
  const [open, setOpen] = useState<Record<string,boolean>>({})
  const [selected,setSelected]=useState<Record<string,boolean>>({})
  const [amounts,setAmounts]=useState<Record<string,string>>({})
  const [roundUp,setRoundUp]=useState(false)
  const [confirm,setConfirm]=useState<string|null>(null)
  const [busy,setBusy]=useState(false)
  const [error,setError]=useState('')
  const [sessions,setSessions]=useState<Record<string,CKSession[]>>({})
  const [loadingSessions,setLoadingSessions]=useState<Record<string,boolean>>({})
  const [showSessions,setShowSessions]=useState<Record<string,boolean>>({})
  const requestId=useRef(crypto.randomUUID())
  const periodById=useMemo(()=>new Map(periods.map(p=>[p.id,p])),[periods])
  const groupById=useMemo(()=>new Map(groups.map(g=>[g.id,g])),[groups])
  const transferMonth=(t: CKTransfer)=>t.origin_month || (t.period_id && periodById.get(t.period_id)?.period_month) || currentMonth
  const rowsFor=(groupId: string,month: string)=>transfers.filter(t=>t.group_id===groupId && transferMonth(t)===month && (t.debtor_user_id===userId||t.creditor_user_id===userId))
  const suggestedFor=(groupId: string,month: string)=>month===currentMonth ? openSuggestions.filter(t=>t.group_id===groupId&&t.debtor_user_id===userId) : []
  const months=useMemo(()=>{
    const set=new Map<string,{groupId:string;month:string}>()
    const add=(groupId:string,month:string)=>{if(groupById.has(groupId))set.set(groupMonthKey(groupId,month),{groupId,month})}
    for(const g of groups)add(g.id,currentMonth)
    for(const p of periods)add(p.group_id,p.period_month)
    for(const p of pendingMonths)add(p.group_id,p.period_month)
    for(const t of transfers){const m=t.origin_month||(t.period_id&&periodById.get(t.period_id)?.period_month);if(m)add(t.group_id,m)}
    return [...set.values()].sort((a,b)=>b.month.localeCompare(a.month)||groups.findIndex(g=>g.id===a.groupId)-groups.findIndex(g=>g.id===b.groupId))
  },[groups,periods,pendingMonths,transfers,currentMonth,periodById,groupById])
  const current=months.filter(x=>x.month===currentMonth)
  const previous=months.filter(x=>x.month<currentMonth)
  const name=(groupId:string,id:string)=>{
    const b=overviews.find(o=>o.id===groupId)?.balances.find(x=>x.user_id===id)
    return b ? [b.first_name,b.last_name].filter(Boolean).join(' ')||'Colleague' : 'Colleague'
  }
  // A pending claim reserves a transfer, so it is counted in outstanding until
  // recipient confirmation; confirmed amounts are subtracted exactly once.
  const total=totalOutstanding(transfers,openSuggestions,userId)
  const touch=()=>{requestId.current=crypto.randomUUID();setConfirm(null);setError('')}
  async function perform(work:()=>Promise<void>){setBusy(true);setError('');try{await work();setSelected({});setAmounts({});setConfirm(null);requestId.current=crypto.randomUUID()}catch(e){setError(describeAppError(e))}finally{setBusy(false)}}
  const amountFor=(key:string,maximum:number)=>{
    if(amounts[key]===undefined)return maximum
    try{return rupeesToPaisa(amounts[key])}catch{return NaN}
  }
  function chosenFor(groupId:string,month:string) {
    const older=rowsFor(groupId,month).filter(t=>t.debtor_user_id===userId&&t.status==='unpaid'&&dueOf(t)>0&&selected[t.id])
      .map(t=>({key:t.id,kind:'existing' as const,amount:amountFor(t.id,dueOf(t)),max:dueOf(t),recipient:t.creditor_user_id}))
    const next=suggestedFor(groupId,month).filter(s=>selected[`new:${groupId}:${s.creditor_user_id}`])
      .map(s=>({key:`new:${groupId}:${s.creditor_user_id}`,kind:'new' as const,amount:amountFor(`new:${groupId}:${s.creditor_user_id}`,safeNumber(s.amount_paisa)),max:safeNumber(s.amount_paisa),recipient:s.creditor_user_id}))
    return [...older,...next]
  }
  async function submit(groupId:string,month:string){
    const rows=chosenFor(groupId,month)
    if(!rows.length)return
    if(rows.some(r=>!Number.isSafeInteger(r.amount)||r.amount<1||r.amount>r.max)){setError('Choose a valid amount for each selected transfer, up to its outstanding balance.');return}
    await perform(async()=>{
      // An open-month batch uses the existing early-payment RPC. A finalized
      // transfer batch uses the new partial-payment RPC.
      const prior=rows.filter(r=>r.kind==='existing')
      const fresh=rows.filter(r=>r.kind==='new')
      // Do not mix two independent operations in one UI submission. This
      // prevents an ambiguous partial success across unrelated RPC calls.
      if(prior.length&&fresh.length)throw new Error('Select current net suggestions or existing payment instructions in separate batches.')
      if(prior.length)await onBatchClaim(prior.map(r=>r.key),prior.map(r=>r.amount),requestId.current,roundUp)
      else await onEarlyClaim(groupId,fresh.map(r=>({recipient:r.recipient,amountPaisa:r.amount})),requestId.current,roundUp)
    })
  }
  async function openSessions(groupId:string,month:string){
    const key=groupMonthKey(groupId,month)
    setShowSessions(v=>({...v,[key]:!v[key]}))
    if(sessions[key]||!supabase)return
    setLoadingSessions(v=>({...v,[key]:true}))
    const {data,error:e}=await supabase.rpc('my_month_session_details',{p_group_id:groupId,p_month:month})
    setLoadingSessions(v=>({...v,[key]:false}))
    if(e){setError(describeAppError(e));return}
    setSessions(v=>({...v,[key]:(data??[]) as CKSession[]}))
  }
  // Refresh explanatory sessions after source data changes (payment state is
  // refreshed by parent). Close/reopen intentionally refetches on next click.
  useEffect(()=>{setSessions({})},[transfers.length,periods.length,openSuggestions.length])
  function card(groupId:string,month:string){
    const group=groupById.get(groupId)
    if(!group)return null
    const key=groupMonthKey(groupId,month)
    const mine=rowsFor(groupId,month)
    const suggested=suggestedFor(groupId,month)
    const pendingMonth=pendingMonths.find(p=>p.group_id===groupId&&p.period_month===month)
    const hasPeriod=periods.some(p=>p.group_id===groupId&&p.period_month===month)
    const due=mine.filter(t=>t.debtor_user_id===userId).reduce((n,t)=>n+dueOf(t),0)+suggested.reduce((n,s)=>n+safeNumber(s.amount_paisa),0)
    const mySelected=chosenFor(groupId,month)
    const totalChosen=mySelected.reduce((n,r)=>n+(Number.isFinite(r.amount)?r.amount:0),0)
    const expanded=open[key]??(month===currentMonth)
    return <article key={key} className={`ck39-month ${pendingMonth?'ck39-needs-action':''}`}>
      <button type="button" className="ck39-month-head" aria-expanded={expanded} onClick={()=>setOpen(s=>({...s,[key]:!expanded}))}>
        <span><strong>{monthLabel(month)}</strong><small>{group.name} · {month===currentMonth?'Current month':pendingMonth?'Awaiting finalization':hasPeriod?'Month finalized':'Past month'}</small></span>
        <span className="ck39-month-total"><strong>{money(due)}</strong><small>{pendingMonth?'Calculation pending':due>0?'To pay':'Nothing owed'}</small></span>
        <span className={`ck39-chevron ${expanded?'expanded':''}`}>⌄</span>
      </button>
      {expanded&&<div className="ck39-month-body">
        {pendingMonth&&<div className="ck39-recovery" role="status">
          <div><strong>Month needs finalization</strong><p>{pendingMonth.session_count} sessions · {money(pendingMonth.total_paisa)} in group bills. This is not your personal debt.</p></div>
          {pendingMonth.can_close?<button type="button" className="ck39-outline" disabled={busy} onClick={()=>setConfirm(confirm===`close:${key}`?null:`close:${key}`)}>Review &amp; finalize</button>:<span className="ck39-tag">Waiting for owner or scheduler</span>}
          {confirm===`close:${key}`&&<div className="ck39-confirm"><p>Finalize {monthLabel(month)}? This fixes the month's net instructions and prevents backdated bills. It does not mark payments received.</p><button className="ck39-outline" onClick={()=>setConfirm(null)}>Cancel</button><button className="ck39-primary" disabled={busy} onClick={()=>void perform(()=>onCloseMonth(groupId,month))}>Finalize month</button></div>}
        </div>}
        <div className="ck39-list" aria-label={`Payments for ${group.name}, ${monthLabel(month)}`}>
          {mine.map(t=>{
            const debtor=t.debtor_user_id===userId,other=debtor?t.creditor_user_id:t.debtor_user_id
            const dueNow=dueOf(t),pendingClaim=claims.find(c=>c.transfer_id===t.id&&c.status==='pending')
            const lastConfirm=claims.filter(c=>c.transfer_id===t.id&&c.status==='confirmed')
            const canSelect=debtor&&t.status==='unpaid'&&dueNow>0
            return <div key={t.id} className="ck39-item">
              <div className="ck39-item-main">
                {canSelect?<input type="checkbox" aria-label={`Select payment to ${name(groupId,other)}`} checked={!!selected[t.id]} onChange={e=>{touch();setSelected(s=>({...s,[t.id]:e.target.checked}))}}/>:<span className="ck39-marker"/>}
                <div><strong>{debtor?'Pay':'Receive from'} {name(groupId,other)}</strong><small>{paymentStatus(t)} · {t.source==='early'?'Early settlement':'Monthly net settlement'}{t.applied_paisa>0?` · ${money(t.applied_paisa)} confirmed`:''}</small></div>
                <b>{money(dueNow)}</b>
              </div>
              {canSelect&&selected[t.id]&&<div className="ck39-amount"><label htmlFor={`amount-${t.id}`}>Amount you're paying (Rs.)</label><input id={`amount-${t.id}`} inputMode="decimal" type="number" min="0.01" step="0.01" max={(dueNow/100).toFixed(2)} value={amounts[t.id]??(dueNow/100).toFixed(2)} onChange={e=>{touch();setAmounts(s=>({...s,[t.id]:e.target.value}))}}/><small>Available {money(dueNow)}. Partial payments are allowed.</small></div>}
              {!debtor&&t.status==='awaiting_confirmation'&&pendingClaim&&<div className="ck39-confirm-receipt"><span>Reported received: {money(pendingClaim.actual_paid_paisa)}</span><button className="ck39-primary" disabled={busy} onClick={()=>void perform(()=>onConfirm(pendingClaim.id,true))}>Confirm received</button><button className="ck39-outline" disabled={busy} onClick={()=>void perform(()=>onConfirm(pendingClaim.id,false))}>Not received</button></div>}
              {lastConfirm.length>0&&t.status!=='confirmed'&&<small className="ck39-paid-history">{lastConfirm.length} confirmed installment{lastConfirm.length>1?'s':''} recorded</small>}
            </div>
          })}
          {suggested.map(s=>{
            const id=`new:${groupId}:${s.creditor_user_id}`,amount=safeNumber(s.amount_paisa)
            return <div key={id} className="ck39-item"><div className="ck39-item-main">
              <input type="checkbox" aria-label={`Select current net balance to ${name(groupId,s.creditor_user_id)}`} checked={!!selected[id]} onChange={e=>{touch();setSelected(v=>({...v,[id]:e.target.checked}))}}/>
              <div><strong>Pay {name(groupId,s.creditor_user_id)}</strong><small>Current net amount · changes as new sessions are recorded</small></div><b>{money(amount)}</b>
            </div>{selected[id]&&<div className="ck39-amount"><label htmlFor={`amount-${id}`}>Amount you're paying (Rs.)</label><input id={`amount-${id}`} inputMode="decimal" type="number" step="0.01" min="0.01" max={(amount/100).toFixed(2)} value={amounts[id]??(amount/100).toFixed(2)} onChange={e=>{touch();setAmounts(v=>({...v,[id]:e.target.value}))}}/><small>You can pay part now and leave the rest for later.</small></div>}</div>
          })}
          {!mine.length&&!suggested.length&&<p className="ck39-no-payments">No payment instructions for you in this group/month{pendingMonth?' until the month is finalized':''}.</p>}
        </div>
        {mySelected.length>0&&<div className="ck39-payment-bar"><label className="ck39-round"><input type="checkbox" checked={roundUp} onChange={e=>{touch();setRoundUp(e.target.checked)}}/> Round each payment up to whole rupees</label><div><strong>{mySelected.length} selected · {money(roundUp?mySelected.reduce((n,r)=>n+(Number.isFinite(r.amount)?wholeRupeeRoundUp(r.amount):0),0):totalChosen)}</strong><button className="ck39-primary" disabled={busy} onClick={()=>setConfirm(confirm===`pay:${key}`?null:`pay:${key}`)}>Mark selected as paid</button></div>
          {confirm===`pay:${key}`&&<div className="ck39-confirm"><p>Have you already paid these {mySelected.length} obligations outside Chai Khapa? They will await individual recipient confirmation.</p><button className="ck39-outline" onClick={()=>setConfirm(null)}>Cancel</button><button className="ck39-primary" disabled={busy} onClick={()=>void submit(groupId,month)}>Yes, request confirmation</button></div>}
        </div>}
        <div className="ck39-session-explain"><button className="ck39-toggle" type="button" onClick={()=>void openSessions(groupId,month)} aria-expanded={!!showSessions[key]}>Sessions behind this month's balance <span>⌄</span></button>
          {showSessions[key]&&(loadingSessions[key]?<p>Loading sessions…</p>:(sessions[key]?.length?<div className="ck39-sessions">{sessions[key].map(s=><div className="ck39-session" key={s.expense_id}><div><strong>{s.description||'Chai session'}</strong><small>{new Date(s.occurred_at).toLocaleDateString('en-PK',{day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Karachi'})} · Bill {money(s.bill_paisa)}</small></div><div><small>Your share {money(s.my_share_paisa)}</small><small>You contributed {money(s.my_contribution_paisa)}</small></div></div>)}</div>:<p className="ck39-muted">No sessions involving you in this month.</p>))}
          <p className="ck39-note">Sessions explain your share and contributions. Payments apply to <b>net balances</b>, not to individual session charges.</p>
        </div>
      </div>}
    </article>
  }
  return <div className="ck39-root"><div className="page-heading short"><div><p className="micro accent">THE SHARED TAB</p><h1>Settlements<span className="punctuation">.</span></h1><p>Pay what you owe, when you want. Every receipt is confirmed.</p></div></div>
    <div className="ck39-summary"><div><p className="micro">OUTSTANDING NET PAYMENTS</p><strong>{money(total)}</strong><p>Includes awaiting-confirmation claims. Unfinalized older months are shown below.</p></div><div><p className="micro">HOW PAYMENTS WORK</p><p>Choose one or more net obligations and enter how much you actually paid. Recipients confirm money received. Existing confirmed installments are never charged again.</p></div></div>
    {error&&<div className="ck39-error" role="alert">{error}</div>}
    <section className="ck39-section" aria-labelledby="ck39-current"><div className="ck39-section-head"><div><p className="micro accent">01 / ACTIVE</p><h2 id="ck39-current">Current month <span>{monthLabel(currentMonth)}</span></h2></div></div>
      {loading?<p className="ck39-muted">Loading current balances…</p>:current.map(x=>card(x.groupId,x.month))}
    </section>
    <section className="ck39-section" aria-labelledby="ck39-previous"><div className="ck39-section-head"><div><p className="micro accent">02 / HISTORY</p><h2 id="ck39-previous">Previous months</h2></div></div>
      {loading?<p className="ck39-muted">Loading previous months…</p>:previous.length?previous.map(x=>card(x.groupId,x.month)):<p className="ck39-no-history">Previous months will appear here once sessions are recorded or periods are finalized.</p>}
    </section>
  </div>
}
