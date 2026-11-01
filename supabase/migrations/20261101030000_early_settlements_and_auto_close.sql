-- Chai Khapa | Phase 3.7: early-settlement claims + automatic closure.
-- AFTER 20261101020000_monthly_settlements.sql. Review and back up before deploying.
-- Supabase Cron activation is a separate, explicit post-migration step.
begin;

-- Fix earlier migration: notification target type for transfers was not allowed
-- by the original CHECK constraint. This prevented closings with transfers.
alter table public.notifications drop constraint if exists notifications_target_check;
alter table public.notifications add constraint notifications_target_check check (
  (target_type is null and target_id is null) or
  (target_type in ('group','expense','settlement','payment','settlement_transfer') and target_id is not null)
);

-- Keep existing month-end transfers and claims; allow extra transfer rows
-- representing payments initiated in an OPEN calendar month.
alter table public.settlement_transfers alter column period_id drop not null;
alter table public.settlement_transfers
  add column source text not null default 'month_end',
  add column origin_month date,
  add column early_batch_id uuid;
alter table public.settlement_transfers add constraint settlement_transfers_source_ck check (
  (source='month_end' and period_id is not null and origin_month is null and early_batch_id is null) or
  (source='early' and period_id is null and origin_month is not null and early_batch_id is not null
    and extract(day from origin_month)=1)
);
create unique index settlement_early_batch_member_pair_uq on public.settlement_transfers
  (group_id,debtor_user_id,early_batch_id,creditor_user_id) where source='early';
create index settlement_early_by_month_idx on public.settlement_transfers
  (group_id,origin_month,debtor_user_id) where source='early';
alter table public.settlement_periods add column closed_method text not null default 'manual'
  constraint settlement_periods_closed_method_ck check (closed_method in ('manual','automatic'));

-- Keep all privileged writes behind security-definer functions. A caller
-- cannot set actor ID in the public RPC; the private core is NOT executable
-- by anon/authenticated or PUBLIC.
create function app_private.close_settlement_month_core(p_group_id uuid, p_month date, p_actor_id uuid, p_auto boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
 v_actor uuid := p_actor_id; v_g public.groups%rowtype; v_period uuid;
 v_start timestamptz; v_end timestamptz;
 v_debtors uuid[] := '{}'; v_creditors uuid[] := '{}';
 v_debts bigint[] := '{}'; v_credits bigint[] := '{}';
 v_di int := 1; v_ci int := 1; v_amount bigint; v_sum bigint := 0;
 v_row record; v_debtor uuid; v_creditor uuid; v_transfer_id uuid;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_month is null or extract(day from p_month)<>1 then
   raise exception 'Choose the first date of a calendar month' using errcode='22023'; end if;
 select * into v_g from public.groups where id=p_group_id for update;
 if not found then raise exception 'Unknown group' using errcode='22023'; end if;
 if not exists(select 1 from public.group_members gm where gm.group_id=p_group_id
      and gm.user_id=v_actor and gm.left_at is null and gm.role='owner'
      and v_g.owner_user_id=v_actor) then
   raise exception 'Only the group owner can close a month' using errcode='42501'; end if;

 select sp.id into v_period from public.settlement_periods sp
   where sp.group_id=p_group_id and sp.period_month=p_month;
 if v_period is not null then return v_period; end if;

 v_start := (p_month::timestamp at time zone v_g.timezone);
 v_end := ((p_month + interval '1 month')::timestamp at time zone v_g.timezone);
 if v_end > now() then raise exception 'You cannot close a month before it finishes' using errcode='22023'; end if;

 insert into public.settlement_periods(group_id,period_month,start_at,end_at,closed_by_user_id,closed_method)
 values (p_group_id,p_month,v_start,v_end,v_actor,case when p_auto then 'automatic' else 'manual' end) returning id into v_period;

 -- Aggregate each person's expenses for THIS period only, including historical members.
 for v_row in
  with paid as (
    select e.paid_by_user_id uid, sum(e.amount_paisa)::bigint amt from public.expenses e
    where e.group_id=p_group_id and e.voided_at is null and e.occurred_at>=v_start and e.occurred_at<v_end
    group by e.paid_by_user_id
  ), shares as (
    select s.user_id uid, sum(s.share_paisa)::bigint amt
    from public.expense_shares s join public.expenses e on e.id=s.expense_id
    where e.group_id=p_group_id and e.voided_at is null and e.occurred_at>=v_start and e.occurred_at<v_end
    group by s.user_id
  ), reserved_early_out as (
    select debtor_user_id uid,sum(amount_paisa)::bigint amt
    from public.settlement_transfers
    where group_id=p_group_id and source='early' and origin_month=p_month
    group by debtor_user_id
  ), reserved_early_in as (
    select creditor_user_id uid,sum(amount_paisa)::bigint amt
    from public.settlement_transfers
    where group_id=p_group_id and source='early' and origin_month=p_month
    group by creditor_user_id
  ), totals as (
    select gm.user_id, (coalesce(pd.amt,0)-coalesce(sh.amt,0)
      +coalesce(reo.amt,0)-coalesce(rei.amt,0))::bigint net
    from public.group_members gm
    left join paid pd on pd.uid=gm.user_id
    left join shares sh on sh.uid=gm.user_id
    left join reserved_early_out reo on reo.uid=gm.user_id
    left join reserved_early_in rei on rei.uid=gm.user_id
    where gm.group_id=p_group_id
  ) select user_id, net from totals where net<>0 order by user_id
 loop
   v_sum := v_sum + v_row.net;
   if v_row.net < 0 then
     v_debtors := array_append(v_debtors,v_row.user_id);
     v_debts := array_append(v_debts,-v_row.net);
   else
     v_creditors := array_append(v_creditors,v_row.user_id);
     v_credits := array_append(v_credits,v_row.net);
   end if;
 end loop;
 if v_sum<>0 then raise exception 'Unbalanced ledger; refusing to settle' using errcode='23514'; end if;

 while v_di<=coalesce(array_length(v_debtors,1),0) and v_ci<=coalesce(array_length(v_creditors,1),0) loop
   v_amount := least(v_debts[v_di],v_credits[v_ci]);
   v_debtor := v_debtors[v_di]; v_creditor := v_creditors[v_ci];
   insert into public.settlement_transfers(period_id,group_id,debtor_user_id,creditor_user_id,amount_paisa)
     values(v_period,p_group_id,v_debtor,v_creditor,v_amount) returning id into v_transfer_id;
   insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
     values(v_debtor,p_group_id,'settlement:'||v_transfer_id||':owed','settlement_due',
       'Monthly settlement ready','Your monthly chai settlement is ready.','settlement_transfer',v_transfer_id),
       (v_creditor,p_group_id,'settlement:'||v_transfer_id||':receive','settlement_receivable',
       'Monthly settlement ready','Someone needs to settle their chai share with you.','settlement_transfer',v_transfer_id)
     on conflict (recipient_user_id,event_key) do nothing;
   v_debts[v_di] := v_debts[v_di]-v_amount;
   v_credits[v_ci] := v_credits[v_ci]-v_amount;
   if v_debts[v_di]=0 then v_di := v_di+1; end if;
   if v_credits[v_ci]=0 then v_ci := v_ci+1; end if;
 end loop;
 return v_period;
end $$;

revoke all on function app_private.close_settlement_month_core(uuid,date,uuid,boolean) from public,anon,authenticated;

-- Preserve the previously deployed public.close_settlement_month RPC and
-- its permission checks. A user cannot impersonate the scheduler.
create or replace function app_private.close_settlement_month(p_group_id uuid,p_month date)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_actor uuid := auth.uid();
begin
  if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  return app_private.close_settlement_month_core(p_group_id,p_month,v_actor,false);
end $$;

-- Suggested transfers only for the current OPEN calendar month. Reserved
-- early payments count as allocated, whether awaiting, confirmed, or rejected
-- (rejected transfers remain an explicit payable obligation until retried).
create function app_private.open_month_suggestions(p_group_id uuid)
returns table(debtor_user_id uuid,creditor_user_id uuid,amount_paisa bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_tz text; v_month date; v_start timestamptz; v_end timestamptz;
 v_debtors uuid[]:='{}'; v_creditors uuid[]:='{}';
 v_debts bigint[]:='{}'; v_credits bigint[]:='{}';
 v_d int:=1; v_c int:=1; v_row record; v_sum bigint:=0; v_amt bigint;
begin
  if auth.uid() is null or not exists (
    select 1 from public.group_members gm where gm.group_id=p_group_id
      and gm.user_id=auth.uid() and gm.left_at is null
  ) then raise exception 'Not a current member' using errcode='42501'; end if;
  select g.timezone into v_tz from public.groups g where g.id=p_group_id;
  if v_tz is null then raise exception 'Group not found' using errcode='22023'; end if;
  v_month := date_trunc('month', now() at time zone v_tz)::date;
  if exists(select 1 from public.settlement_periods sp
    where sp.group_id=p_group_id and sp.period_month=v_month) then return; end if;
  v_start := v_month::timestamp at time zone v_tz;
  v_end := (v_month + interval '1 month')::timestamp at time zone v_tz;
  for v_row in
    with paid as (
      select e.paid_by_user_id uid,sum(e.amount_paisa)::bigint amt from public.expenses e
      where e.group_id=p_group_id and e.voided_at is null and e.occurred_at>=v_start and e.occurred_at<v_end
      group by e.paid_by_user_id
    ), shares as (
      select es.user_id uid,sum(es.share_paisa)::bigint amt
      from public.expense_shares es join public.expenses e on e.id=es.expense_id
      where e.group_id=p_group_id and e.voided_at is null
        and e.occurred_at>=v_start and e.occurred_at<v_end
      group by es.user_id
    ), reservations_out as (
      select t.debtor_user_id uid,sum(t.amount_paisa)::bigint amt from public.settlement_transfers t
      where t.group_id=p_group_id and t.source='early' and t.origin_month=v_month group by t.debtor_user_id
    ), reservations_in as (
      select t.creditor_user_id uid,sum(t.amount_paisa)::bigint amt from public.settlement_transfers t
      where t.group_id=p_group_id and t.source='early' and t.origin_month=v_month group by t.creditor_user_id
    )
    select gm.user_id,(coalesce(p.amt,0)-coalesce(s.amt,0)+coalesce(ro.amt,0)-coalesce(ri.amt,0))::bigint net
      from public.group_members gm
      left join paid p on p.uid=gm.user_id
      left join shares s on s.uid=gm.user_id
      left join reservations_out ro on ro.uid=gm.user_id
      left join reservations_in ri on ri.uid=gm.user_id
      where gm.group_id=p_group_id
      order by gm.user_id
  loop
    v_sum:=v_sum+v_row.net;
    if v_row.net<0 then
      v_debtors:=array_append(v_debtors,v_row.user_id);
      v_debts:=array_append(v_debts,-v_row.net);
    elsif v_row.net>0 then
      v_creditors:=array_append(v_creditors,v_row.user_id);
      v_credits:=array_append(v_credits,v_row.net);
    end if;
  end loop;
  if v_sum<>0 then raise exception 'Ledger is unbalanced' using errcode='23514'; end if;
  while v_d<=coalesce(array_length(v_debtors,1),0) and v_c<=coalesce(array_length(v_creditors,1),0) loop
    v_amt:=least(v_debts[v_d],v_credits[v_c]);
    debtor_user_id:=v_debtors[v_d]; creditor_user_id:=v_creditors[v_c]; amount_paisa:=v_amt;
    return next;
    v_debts[v_d]:=v_debts[v_d]-v_amt;
    v_credits[v_c]:=v_credits[v_c]-v_amt;
    if v_debts[v_d]=0 then v_d:=v_d+1; end if;
    if v_credits[v_c]=0 then v_c:=v_c+1; end if;
  end loop;
end $$;
create function public.get_open_month_suggestions(p_group_id uuid)
returns table(debtor_user_id uuid,creditor_user_id uuid,amount_paisa bigint)
language sql security invoker set search_path='' as $$
  select * from app_private.open_month_suggestions(p_group_id)
$$;
revoke all on function app_private.open_month_suggestions(uuid) from public,anon,authenticated;
grant execute on function app_private.open_month_suggestions(uuid) to authenticated;
revoke all on function public.get_open_month_suggestions(uuid) from public,anon,authenticated;
grant execute on function public.get_open_month_suggestions(uuid) to authenticated;

-- A batch creates transfers AND pending receipt claims in one transaction.
-- No user can forge a creditor/amount: each requested pair must exactly match
-- the server's current suggestions. Single group per batch, atomic or nothing.
-- Retrying with the same UUID returns the original claims.
create function app_private.claim_early_settlements(
  p_group_id uuid,p_creditor_user_ids uuid[],p_amounts_paisa bigint[],p_request_id uuid,p_round_up boolean
) returns uuid[] language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_group public.groups%rowtype; v_month date;
  v_count int; v_i int; v_expected bigint; v_paid bigint; v_transfer uuid; v_claim uuid;
  v_result uuid[]:='{}'; v_existing record; v_existing_count int; v_requested_count int;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_request_id is null then raise exception 'A retry-safe request id is required' using errcode='22023'; end if;
  v_count:=coalesce(array_length(p_creditor_user_ids,1),0);
  if v_count<1 or v_count>30 or v_count<>coalesce(array_length(p_amounts_paisa,1),0) then
    raise exception 'Choose 1–30 transfers, with one amount each' using errcode='22023'; end if;
  if p_round_up is null then raise exception 'Choose rounding preference' using errcode='22023'; end if;
  -- Lock same group row used by expense writes and month close.
  select * into v_group from public.groups where id=p_group_id for update;
  if not found or v_group.archived_at is not null then
    raise exception 'Group is missing or archived' using errcode='22023'; end if;
  if not exists(select 1 from public.group_members where group_id=p_group_id and user_id=v_actor and left_at is null) then
    raise exception 'Not an active member' using errcode='42501'; end if;
  v_month:=date_trunc('month',now() at time zone v_group.timezone)::date;
  if exists (select 1 from public.settlement_periods where group_id=p_group_id and period_month=v_month) then
    raise exception 'This month is closed' using errcode='22023'; end if;
  -- Check idempotency BEFORE comparing against newly updated balances.
  select count(*) into v_existing_count from public.settlement_transfers
   where group_id=p_group_id and debtor_user_id=v_actor and source='early' and early_batch_id=p_request_id;
  if v_existing_count>0 then
    if v_existing_count<>v_count then raise exception 'Request key reused with different selection' using errcode='22023'; end if;
    for v_i in 1..v_count loop
      select t.amount_paisa,c.id into v_expected,v_claim
      from public.settlement_transfers t join public.settlement_payment_claims c on c.transfer_id=t.id
      where t.group_id=p_group_id and t.debtor_user_id=v_actor and t.source='early'
        and t.early_batch_id=p_request_id and t.creditor_user_id=p_creditor_user_ids[v_i]
      order by c.created_at limit 1;
      if v_claim is null or v_expected is distinct from p_amounts_paisa[v_i] then
        raise exception 'Request key reused with different selection' using errcode='22023'; end if;
      v_result:=array_append(v_result,v_claim);
    end loop;
    return v_result;
  end if;
  if (select count(distinct u) from unnest(p_creditor_user_ids) u)<>v_count then
    raise exception 'Duplicate recipients are not allowed' using errcode='22023'; end if;
  -- Validate ALL pairs against the SAME balance snapshot before writing.
  for v_i in 1..v_count loop
    if p_creditor_user_ids[v_i] is null or p_amounts_paisa[v_i] is null or p_amounts_paisa[v_i]<=0 then
      raise exception 'Invalid recipient or amount' using errcode='22023'; end if;
    select s.amount_paisa into v_expected from app_private.open_month_suggestions(p_group_id) s
      where s.debtor_user_id=v_actor and s.creditor_user_id=p_creditor_user_ids[v_i];
    if v_expected is null or v_expected<>p_amounts_paisa[v_i] then
      raise exception 'Balance changed; refresh before paying' using errcode='22023'; end if;
  end loop;
  for v_i in 1..v_count loop
    v_expected:=p_amounts_paisa[v_i];
    v_paid:=case when p_round_up then ((v_expected+99)/100)*100 else v_expected end;
    insert into public.settlement_transfers(
      period_id,group_id,debtor_user_id,creditor_user_id,amount_paisa,status,source,origin_month,early_batch_id
    ) values(null,p_group_id,v_actor,p_creditor_user_ids[v_i],v_expected,'awaiting_confirmation',
        'early',v_month,p_request_id) returning id into v_transfer;
    insert into public.settlement_payment_claims(
      transfer_id,claimed_by_user_id,actual_paid_paisa,rounding_adjustment_paisa
    ) values(v_transfer,v_actor,v_paid,v_paid-v_expected) returning id into v_claim;
    v_result:=array_append(v_result,v_claim);
    insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
    values(p_creditor_user_ids[v_i],p_group_id,'payment:'||v_claim||':claimed',
      'payment_claimed','Early chai payment reported',
      'A group member says they paid you early. Confirm receipt in Settlements.',
      'settlement_transfer',v_transfer)
    on conflict(recipient_user_id,event_key) do nothing;
  end loop;
  return v_result;
end $$;
create function public.claim_early_settlements(
  p_group_id uuid,p_creditor_user_ids uuid[],p_amounts_paisa bigint[],p_request_id uuid,p_round_up boolean default true
) returns uuid[] language sql security invoker set search_path='' as $$
  select app_private.claim_early_settlements(p_group_id,p_creditor_user_ids,p_amounts_paisa,p_request_id,p_round_up)
$$;
revoke all on function app_private.claim_early_settlements(uuid,uuid[],bigint[],uuid,boolean) from public,anon,authenticated;
grant execute on function app_private.claim_early_settlements(uuid,uuid[],bigint[],uuid,boolean) to authenticated;
revoke all on function public.claim_early_settlements(uuid,uuid[],bigint[],uuid,boolean) from public,anon,authenticated;
grant execute on function public.claim_early_settlements(uuid,uuid[],bigint[],uuid,boolean) to authenticated;

-- Observability for failures. No access by browser roles.
create table public.settlement_job_log (
  id bigint generated always as identity primary key,
  group_id uuid references public.groups(id) on delete restrict,
  period_month date,
  ran_at timestamptz not null default now(),
  outcome text not null check(outcome in ('closed','skipped','failed')),
  period_id uuid,
  error_text text
);
alter table public.settlement_job_log enable row level security;
revoke all on table public.settlement_job_log from public,anon,authenticated;

-- Cron runs with the postgres DB role; functions are inaccessible to browser
-- roles. Each month is tried in a subtransaction, so a bad group doesn't block
-- all other groups. Up to 24 missed months/group/run after project revival.
create function app_private.run_auto_month_closures()
returns integer language plpgsql security definer set search_path='' as $$
declare v_g record; v_month date; v_current_month date; v_first_month date;
  v_actor uuid; v_closed int:=0; v_period uuid; v_attempts int;
begin
  for v_g in select id,owner_user_id,timezone from public.groups order by id loop
    v_current_month:=date_trunc('month',now() at time zone v_g.timezone)::date;
    select min(date_trunc('month',e.occurred_at at time zone v_g.timezone)::date)
      into v_first_month from public.expenses e where e.group_id=v_g.id and e.voided_at is null;
    if v_first_month is null or v_first_month>=v_current_month then continue; end if;
    v_attempts:=0;
    for v_month in select gs::date from pg_catalog.generate_series(
      v_first_month::timestamp, (v_current_month - interval '1 month')::timestamp,
      interval '1 month') gs order by gs
    loop
      if v_attempts >= 24 then exit; end if;
      if exists(select 1 from public.settlement_periods sp
        where sp.group_id=v_g.id and sp.period_month=v_month) then continue; end if;
      v_attempts:=v_attempts+1;
      begin
        v_period:=app_private.close_settlement_month_core(v_g.id,v_month,v_g.owner_user_id,true);
        insert into public.settlement_job_log(group_id,period_month,outcome,period_id)
          values(v_g.id,v_month,'closed',v_period);
        v_closed:=v_closed+1;
      exception when others then
        insert into public.settlement_job_log(group_id,period_month,outcome,error_text)
          values(v_g.id,v_month,'failed',left(SQLSTATE || ': ' || SQLERRM,1500));
      end;
    end loop;
  end loop;
  return v_closed;
end $$;
revoke all on function app_private.run_auto_month_closures() from public,anon,authenticated;
-- Do NOT grant to authenticated. Job must be created and run by postgres only.
commit;
