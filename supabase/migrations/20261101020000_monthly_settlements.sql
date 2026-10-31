-- Chai Khapa | Phase 3.6 | Monthly settlements & receipt confirmation.
-- Requires all earlier phases including 20261101010000_group_management.sql.
-- NOTE: this migration has not been run against the user's live Supabase project.
begin;

create table public.settlement_periods (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  period_month date not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  closed_by_user_id uuid not null,
  closed_at timestamptz not null default now(),
  constraint settlement_periods_owner_fk foreign key(group_id, closed_by_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint settlement_periods_month_first check (extract(day from period_month) = 1),
  constraint settlement_periods_dates_check check (end_at > start_at),
  constraint settlement_periods_unique unique(group_id, period_month),
  constraint settlement_periods_id_group_unique unique(id, group_id)
);

create table public.settlement_transfers (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null,
  group_id uuid not null,
  debtor_user_id uuid not null,
  creditor_user_id uuid not null,
  amount_paisa bigint not null check(amount_paisa > 0),
  status text not null default 'unpaid' check(status in ('unpaid','awaiting_confirmation','confirmed')),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint settlement_transfers_period_fk foreign key(period_id,group_id)
    references public.settlement_periods(id,group_id) on delete restrict,
  constraint settlement_transfers_debtor_fk foreign key(group_id,debtor_user_id)
    references public.group_members(group_id,user_id) on delete restrict,
  constraint settlement_transfers_creditor_fk foreign key(group_id,creditor_user_id)
    references public.group_members(group_id,user_id) on delete restrict,
  constraint settlement_transfers_distinct_check check (debtor_user_id <> creditor_user_id),
  constraint settlement_transfers_confirmation_check check ((status='confirmed')=(confirmed_at is not null)),
  constraint settlement_transfers_unique_pair unique (period_id, debtor_user_id, creditor_user_id)
);
create index settlement_transfers_debtor_idx on public.settlement_transfers(debtor_user_id, status);
create index settlement_transfers_creditor_idx on public.settlement_transfers(creditor_user_id, status);

create table public.settlement_payment_claims (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.settlement_transfers(id) on delete restrict,
  claimed_by_user_id uuid not null references public.profiles(user_id) on delete restrict,
  actual_paid_paisa bigint not null check(actual_paid_paisa > 0),
  rounding_adjustment_paisa bigint not null default 0 check (rounding_adjustment_paisa between 0 and 99),
  status text not null default 'pending' check(status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_user_id uuid references public.profiles(user_id) on delete restrict,
  constraint settlement_claim_decision_check check (
    (status='pending' and decided_at is null and decided_by_user_id is null) or
    (status<>'pending' and decided_at is not null and decided_by_user_id is not null)
  )
);
create unique index settlement_one_pending_claim_idx
  on public.settlement_payment_claims(transfer_id) where status='pending';
create unique index settlement_one_confirmed_claim_idx
  on public.settlement_payment_claims(transfer_id) where status='confirmed';
create index settlement_claims_transfer_idx on public.settlement_payment_claims(transfer_id, created_at desc);

-- Default deny. Financial records can be read by current group members,
-- but may be changed ONLY through tightly controlled authenticated RPCs.
revoke all on public.settlement_periods,public.settlement_transfers,public.settlement_payment_claims from public,anon,authenticated;
alter table public.settlement_periods enable row level security;
alter table public.settlement_transfers enable row level security;
alter table public.settlement_payment_claims enable row level security;
grant select on public.settlement_periods,public.settlement_transfers,public.settlement_payment_claims to authenticated;

create policy settlement_periods_group_read on public.settlement_periods
  for select to authenticated using (group_id in (select app_private.my_active_group_ids()));
create policy settlement_transfers_group_read on public.settlement_transfers
  for select to authenticated using (group_id in (select app_private.my_active_group_ids()));
create policy settlement_claims_participants_read on public.settlement_payment_claims
  for select to authenticated using (exists (
    select 1 from public.settlement_transfers t where t.id=transfer_id
      and (t.debtor_user_id=(select auth.uid()) or t.creditor_user_id=(select auth.uid()))
  ));

-- Prevent insertion into an already-closed calendar month (PKT/group timezone).
-- Lock the group row, matching the closure RPC, to serialize writes and closes.
create function app_private.prevent_closed_month_expense()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_timezone text;
begin
  select g.timezone into v_timezone from public.groups g where g.id=new.group_id for update;
  if exists (
    select 1 from public.settlement_periods sp
    where sp.group_id=new.group_id
      and sp.period_month=date_trunc('month', new.occurred_at at time zone v_timezone)::date
  ) then
    raise exception 'This calendar month has already been closed for settlement' using errcode='22023';
  end if;
  return new;
end $$;
create trigger chai_khapa_prevent_closed_month_expense before insert on public.expenses
  for each row execute function app_private.prevent_closed_month_expense();
revoke all on function app_private.prevent_closed_month_expense() from public,anon,authenticated;

-- Generate one period per calendar month. Must be the first of the month, and
-- already finished in the group's timezone. Idempotent on repeated requests.
-- This deliberately does NOT net other months into this period: outstanding
-- older months remain separately payable until confirmed.
create function app_private.close_settlement_month(p_group_id uuid, p_month date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
 v_actor uuid := auth.uid(); v_g public.groups%rowtype; v_period uuid;
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

 insert into public.settlement_periods(group_id,period_month,start_at,end_at,closed_by_user_id)
 values (p_group_id,p_month,v_start,v_end,v_actor) returning id into v_period;

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
  ), totals as (
    select gm.user_id, (coalesce(pd.amt,0)-coalesce(sh.amt,0))::bigint net
    from public.group_members gm
    left join paid pd on pd.uid=gm.user_id
    left join shares sh on sh.uid=gm.user_id
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
create function public.close_settlement_month(p_group_id uuid,p_month date)
returns uuid language sql security invoker set search_path='' as $$
 select app_private.close_settlement_month(p_group_id,p_month);
$$;

-- The debtor claims they made the complete payment (cash or external transfer).
-- Whole rupee round-up is optional; extra paisa is transparently recorded.
create function app_private.mark_transfer_paid(p_transfer_id uuid,p_paid_paisa bigint default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_actor uuid := auth.uid(); v_transfer public.settlement_transfers%rowtype;
 v_paid bigint; v_claim_id uuid;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 select * into v_transfer from public.settlement_transfers where id=p_transfer_id for update;
 if not found or v_transfer.debtor_user_id<>v_actor then
   raise exception 'Only the person owing this transfer can claim payment' using errcode='42501'; end if;
 if v_transfer.status<>'unpaid' then
   raise exception 'This transfer is already pending or confirmed' using errcode='22023'; end if;
 v_paid := coalesce(p_paid_paisa,((v_transfer.amount_paisa+99)/100)*100);
 if v_paid<v_transfer.amount_paisa or v_paid>((v_transfer.amount_paisa+99)/100)*100 then
   raise exception 'Paid amount must equal the exact balance or its whole-rupee round-up' using errcode='22023'; end if;
 insert into public.settlement_payment_claims(transfer_id,claimed_by_user_id,actual_paid_paisa,rounding_adjustment_paisa)
 values(v_transfer.id,v_actor,v_paid,v_paid-v_transfer.amount_paisa) returning id into v_claim_id;
 update public.settlement_transfers set status='awaiting_confirmation' where id=p_transfer_id;
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 values(v_transfer.creditor_user_id,v_transfer.group_id,'payment:'||v_claim_id||':claimed',
 'payment_claimed','Please confirm payment','A colleague marked a chai settlement as paid. Confirm you received it.',
 'settlement_transfer',v_transfer.id)
 on conflict(recipient_user_id,event_key) do nothing;
 return v_claim_id;
end $$;
create function public.mark_transfer_paid(p_transfer_id uuid,p_paid_paisa bigint default null)
returns uuid language sql security invoker set search_path='' as $$
 select app_private.mark_transfer_paid(p_transfer_id,p_paid_paisa);
$$;

create function app_private.confirm_transfer_payment(p_claim_id uuid,p_received boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_actor uuid := auth.uid(); v_claim public.settlement_payment_claims%rowtype;
 v_transfer public.settlement_transfers%rowtype;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_received is null then raise exception 'Choose confirm or reject' using errcode='22023'; end if;
 select t.* into v_transfer from public.settlement_transfers t
   join public.settlement_payment_claims c on c.transfer_id=t.id where c.id=p_claim_id for update of t;
 if not found or v_transfer.creditor_user_id<>v_actor then
   raise exception 'Only the recipient may confirm payment' using errcode='42501'; end if;
 select * into v_claim from public.settlement_payment_claims where id=p_claim_id for update;
 if v_claim.status<>'pending' or v_transfer.status<>'awaiting_confirmation' then
   raise exception 'Payment claim has already been decided' using errcode='22023'; end if;
 update public.settlement_payment_claims set status=case when p_received then 'confirmed' else 'rejected' end,
     decided_at=now(),decided_by_user_id=v_actor where id=p_claim_id;
 update public.settlement_transfers set status=case when p_received then 'confirmed' else 'unpaid' end,
     confirmed_at=case when p_received then now() else null end where id=v_transfer.id;
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 values(v_transfer.debtor_user_id,v_transfer.group_id,
   'payment:'||p_claim_id||':decision',
   case when p_received then 'payment_confirmed' else 'payment_rejected' end,
   case when p_received then 'Payment confirmed' else 'Payment not received' end,
   case when p_received then 'Your chai settlement has been confirmed.' else 'The recipient could not confirm your payment. Please coordinate and try again.' end,
   'settlement_transfer',v_transfer.id)
 on conflict(recipient_user_id,event_key) do nothing;
 return p_received;
end $$;
create function public.confirm_transfer_payment(p_claim_id uuid,p_received boolean)
returns boolean language sql security invoker set search_path='' as $$
 select app_private.confirm_transfer_payment(p_claim_id,p_received);
$$;

-- Current net = historical paid - shares, adjusted for CONFIRMED settlements.
-- Pending/unconfirmed claims must NOT change a person's net position.
create or replace function app_private.get_group_balances(p_group_id uuid)
returns table (user_id uuid,first_name text,last_name text,total_paid_paisa bigint,total_share_paisa bigint,net_paisa bigint)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(
   select 1 from public.group_members gm where gm.group_id=p_group_id
     and gm.user_id=auth.uid() and gm.left_at is null
 ) then raise exception 'Not an active member of this group' using errcode='42501'; end if;
 return query
 with paid as (
   select e.paid_by_user_id uid,sum(e.amount_paisa)::bigint amount from public.expenses e
   where e.group_id=p_group_id and e.voided_at is null group by e.paid_by_user_id
 ), consumed as (
   select s.user_id uid,sum(s.share_paisa)::bigint amount from public.expense_shares s
   join public.expenses e on e.id=s.expense_id
   where e.group_id=p_group_id and e.voided_at is null group by s.user_id
 ), confirmed_out as (
   select t.debtor_user_id uid,sum(t.amount_paisa)::bigint amount from public.settlement_transfers t
   where t.group_id=p_group_id and t.status='confirmed' group by t.debtor_user_id
 ), confirmed_in as (
   select t.creditor_user_id uid,sum(t.amount_paisa)::bigint amount from public.settlement_transfers t
   where t.group_id=p_group_id and t.status='confirmed' group by t.creditor_user_id
 )
 select gm.user_id,p.first_name,p.last_name,
   coalesce(pd.amount,0)::bigint,coalesce(cs.amount,0)::bigint,
   (coalesce(pd.amount,0)-coalesce(cs.amount,0)
     +coalesce(co.amount,0)-coalesce(ci.amount,0))::bigint
 from public.group_members gm
 join public.profiles p on p.user_id=gm.user_id
 left join paid pd on pd.uid=gm.user_id
 left join consumed cs on cs.uid=gm.user_id
 left join confirmed_out co on co.uid=gm.user_id
 left join confirmed_in ci on ci.uid=gm.user_id
 where gm.group_id=p_group_id
 order by p.first_name nulls last,p.last_name nulls last,gm.user_id;
end $$;

-- Group departure must use the NEW adjusted net, not raw historical spending.
-- This preserves the rule that nobody may leave with unpaid obligations.
create or replace function app_private.leave_group(p_group_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_actor uuid := auth.uid(); v_role text; v_net bigint;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 select gm.role into v_role from public.group_members gm
 where gm.group_id=p_group_id and gm.user_id=v_actor and gm.left_at is null for update;
 if not found then raise exception 'Not an active member' using errcode='42501'; end if;
 if v_role='owner' then raise exception 'Transfer ownership before leaving' using errcode='22023'; end if;
 select b.net_paisa into v_net from app_private.get_group_balances(p_group_id) b
 where b.user_id=v_actor;
 if v_net is distinct from 0 then
   raise exception 'Settle your outstanding balance before leaving' using errcode='22023'; end if;
 update public.group_members set left_at=now()
 where group_id=p_group_id and user_id=v_actor and left_at is null;
 return true;
end $$;

revoke all on function app_private.close_settlement_month(uuid,date),
  app_private.mark_transfer_paid(uuid,bigint), app_private.confirm_transfer_payment(uuid,boolean)
  from public,anon,authenticated;
grant execute on function app_private.close_settlement_month(uuid,date),
  app_private.mark_transfer_paid(uuid,bigint), app_private.confirm_transfer_payment(uuid,boolean)
  to authenticated;
revoke all on function public.close_settlement_month(uuid,date),
  public.mark_transfer_paid(uuid,bigint), public.confirm_transfer_payment(uuid,boolean)
  from public,anon,authenticated;
grant execute on function public.close_settlement_month(uuid,date),
  public.mark_transfer_paid(uuid,bigint), public.confirm_transfer_payment(uuid,boolean)
  to authenticated;
commit;
