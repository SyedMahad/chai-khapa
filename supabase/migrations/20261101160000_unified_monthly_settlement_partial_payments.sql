-- Chai Khapa Phase 3.9: unified monthly ledger + partial payments.
-- Requires Phase 3.8.3; apply only after local integration tests & a verified backup.
begin;

-- Preserve existing confirmed transfers, and explicitly track how much of each
-- net obligation has been confirmed. NEVER change its original amount.
alter table public.settlement_transfers
  add column applied_paisa bigint not null default 0;
update public.settlement_transfers
set applied_paisa = amount_paisa where status = 'confirmed';
alter table public.settlement_transfers
  add constraint settlement_applied_range_ck
    check (applied_paisa >= 0 and applied_paisa <= amount_paisa);

alter table public.settlement_payment_claims
  add column applied_paisa bigint,
  add column request_id uuid;
update public.settlement_payment_claims c
set applied_paisa = least(c.actual_paid_paisa, t.amount_paisa)
from public.settlement_transfers t
where c.transfer_id = t.id;
alter table public.settlement_payment_claims
  alter column applied_paisa set not null,
  add constraint settlement_claim_applied_positive_ck check (applied_paisa > 0),
  add constraint settlement_claim_actual_not_less_ck check (actual_paid_paisa >= applied_paisa),
  add constraint settlement_claim_rounding_matches_ck check (actual_paid_paisa - applied_paisa = rounding_adjustment_paisa);

-- A transfer can be confirmed in several installments, but only one claim can
-- await a decision for the transfer at any one time.
drop index if exists public.settlement_one_confirmed_claim_idx;
create unique index settlement_claim_request_idempotency_idx
  on public.settlement_payment_claims(claimed_by_user_id,request_id,transfer_id)
  where request_id is not null;

-- Server-authorized atomic batch (works across groups / months).
-- Each selection is an AMOUNT TO APPLY against the obligation, not a raw
-- expense/share. Rounding extra is recorded, never credited toward the debt.
create function app_private.claim_month_payments(
  p_transfer_ids uuid[], p_amounts_paisa bigint[], p_request_id uuid, p_round_up boolean
) returns uuid[] language plpgsql security definer set search_path = '' as $$
declare
  v_actor uuid := auth.uid(); v_count integer; v_existing integer;
  v_result uuid[] := '{}'::uuid[]; v_row record;
  v_transfer public.settlement_transfers%rowtype;
  v_remaining bigint; v_actual bigint; v_claim_id uuid;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_request_id is null or p_round_up is null then
    raise exception 'Request id and rounding preference required' using errcode = '22023'; end if;
  v_count := coalesce(array_length(p_transfer_ids,1),0);
  if v_count < 1 or v_count > 30 or v_count <> coalesce(array_length(p_amounts_paisa,1),0) then
    raise exception 'Choose 1–30 transfers with corresponding amounts' using errcode = '22023'; end if;
  if (select count(distinct x) from unnest(p_transfer_ids) x) <> v_count then
    raise exception 'Duplicate transfer ids' using errcode='22023'; end if;

  -- Retry-safe replay: never create a second set of claims under same key.
  select count(*) into v_existing from public.settlement_payment_claims
    where claimed_by_user_id=v_actor and request_id=p_request_id;
  if v_existing > 0 then
    if v_existing <> v_count then raise exception 'Request id reused with different payments' using errcode='22023'; end if;
    for v_row in select ids.id, ids.amount from unnest(p_transfer_ids,p_amounts_paisa) as ids(id,amount) order by ids.id loop
      select c.id into v_claim_id from public.settlement_payment_claims c
      where c.transfer_id=v_row.id and c.claimed_by_user_id=v_actor
        and c.request_id=p_request_id and c.applied_paisa=v_row.amount
        and c.rounding_adjustment_paisa=case when p_round_up then ((v_row.amount+99)/100)*100-v_row.amount else 0 end;
      if v_claim_id is null then raise exception 'Request id reused with different payments' using errcode='22023'; end if;
      v_result := array_append(v_result,v_claim_id);
    end loop;
    return v_result;
  end if;

  -- Deterministic lock order prevents deadlocks when batches overlap.
  for v_row in select ids.id, ids.amount from unnest(p_transfer_ids,p_amounts_paisa) as ids(id,amount) order by ids.id loop
    if v_row.id is null or v_row.amount is null or v_row.amount < 1 then
      raise exception 'Invalid transfer or amount' using errcode='22023'; end if;
    select * into v_transfer from public.settlement_transfers where id=v_row.id for update;
    if not found or v_transfer.debtor_user_id <> v_actor then
      raise exception 'You can pay only your own obligations' using errcode='42501'; end if;
    if v_transfer.status = 'awaiting_confirmation' then
      raise exception 'Payment already awaiting recipient confirmation' using errcode='22023'; end if;
    v_remaining := v_transfer.amount_paisa-v_transfer.applied_paisa;
    if v_transfer.status='confirmed' or v_row.amount > v_remaining then
      raise exception 'Amount exceeds remaining obligation; refresh' using errcode='22023'; end if;
    v_actual := case when p_round_up then ((v_row.amount+99)/100)*100 else v_row.amount end;
    insert into public.settlement_payment_claims(
      transfer_id, claimed_by_user_id, actual_paid_paisa, applied_paisa,
      rounding_adjustment_paisa, request_id
    ) values(v_transfer.id,v_actor,v_actual,v_row.amount,v_actual-v_row.amount,p_request_id)
    returning id into v_claim_id;
    update public.settlement_transfers set status='awaiting_confirmation' where id=v_transfer.id;
    insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
    values(v_transfer.creditor_user_id,v_transfer.group_id,'payment:'||v_claim_id||':claimed',
      'payment_claimed','Please confirm a chai payment',
      'A group member reported a payment. Please confirm receipt in Settlements.',
      'settlement_transfer',v_transfer.id)
    on conflict(recipient_user_id,event_key) do nothing;
    v_result:=array_append(v_result,v_claim_id);
  end loop;
  return v_result;
end $$;
create function public.claim_month_payments(
  p_transfer_ids uuid[], p_amounts_paisa bigint[], p_request_id uuid,
  p_round_up boolean default false
) returns uuid[] language sql security invoker set search_path='' as $$
  select app_private.claim_month_payments(p_transfer_ids,p_amounts_paisa,p_request_id,p_round_up);
$$;
revoke all on function app_private.claim_month_payments(uuid[],bigint[],uuid,boolean) from public,anon,authenticated;
grant execute on function app_private.claim_month_payments(uuid[],bigint[],uuid,boolean) to authenticated;
revoke all on function public.claim_month_payments(uuid[],bigint[],uuid,boolean) from public,anon,authenticated;
grant execute on function public.claim_month_payments(uuid[],bigint[],uuid,boolean) to authenticated;

-- Existing call path also remains safe after an installment has been received.
create or replace function app_private.mark_transfer_paid(p_transfer_id uuid,p_paid_paisa bigint default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_t public.settlement_transfers%rowtype; v_due bigint; v_actual bigint; v_ids uuid[];
begin
  select * into v_t from public.settlement_transfers where id=p_transfer_id;
  if not found or v_t.debtor_user_id is distinct from auth.uid() then
    raise exception 'Not your settlement transfer' using errcode='42501'; end if;
  v_due:=v_t.amount_paisa-v_t.applied_paisa;
  if v_due <= 0 then raise exception 'Transfer already settled' using errcode='22023'; end if;
  v_actual:=coalesce(p_paid_paisa,((v_due+99)/100)*100);
  if v_actual <> v_due and v_actual <> ((v_due+99)/100)*100 then
    raise exception 'Use the current remaining amount' using errcode='22023'; end if;
  v_ids:=app_private.claim_month_payments(array[p_transfer_id],array[v_due],gen_random_uuid(),v_actual>v_due);
  return v_ids[1];
end $$;

-- Decide a claim precisely once; an accepted installment reduces the remaining
-- debt only by applied_paisa, not by any voluntary round-up.
create or replace function app_private.confirm_transfer_payment(p_claim_id uuid,p_received boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_c public.settlement_payment_claims%rowtype;
  v_t public.settlement_transfers%rowtype; v_new_applied bigint;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_received is null then raise exception 'Choose confirm or reject' using errcode='22023'; end if;
  select t.* into v_t from public.settlement_transfers t
    join public.settlement_payment_claims c on c.transfer_id=t.id
    where c.id=p_claim_id for update of t;
  if not found or v_t.creditor_user_id<>v_actor then
    raise exception 'Only the recipient may confirm payment' using errcode='42501'; end if;
  select * into v_c from public.settlement_payment_claims where id=p_claim_id for update;
  if v_c.status<>'pending' or v_t.status<>'awaiting_confirmation' then
    if v_c.status = (case when p_received then 'confirmed' else 'rejected' end) then return true; end if;
    raise exception 'Claim was already decided' using errcode='22023';
  end if;
  v_new_applied:=v_t.applied_paisa+(case when p_received then v_c.applied_paisa else 0 end);
  if v_new_applied > v_t.amount_paisa then
    raise exception 'Payment would exceed original obligation' using errcode='23514'; end if;
  update public.settlement_payment_claims
    set status=case when p_received then 'confirmed' else 'rejected' end,
      decided_at=now(),decided_by_user_id=v_actor where id=p_claim_id;
  update public.settlement_transfers
    set applied_paisa=v_new_applied,
      status=case when v_new_applied=v_t.amount_paisa then 'confirmed' else 'unpaid' end,
      confirmed_at=case when v_new_applied=v_t.amount_paisa then now() else null end
    where id=v_t.id;
  insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
    values(v_t.debtor_user_id,v_t.group_id,'payment:'||p_claim_id||':decision',
      case when p_received then 'payment_confirmed' else 'payment_rejected' end,
      case when p_received then 'Payment confirmed' else 'Payment not received' end,
      case when p_received then 'Your chai payment was confirmed.' else 'The recipient did not receive the reported payment.' end,
      'settlement_transfer',v_t.id)
    on conflict(recipient_user_id,event_key) do nothing;
  return true;
end $$;

-- For current-month early payments, accept a partial selection <= net suggestion.
-- The early transfer itself still represents exactly the amount chosen, so the
-- existing early-claim confirmation process remains valid.
create or replace function app_private.claim_early_settlements(
  p_group_id uuid,p_creditor_user_ids uuid[],p_amounts_paisa bigint[],p_request_id uuid,p_round_up boolean
) returns uuid[] language plpgsql security definer set search_path='' as $$
declare v_actor uuid:=auth.uid(); v_group public.groups%rowtype; v_month date;
  v_count int; v_i int; v_expected bigint; v_paid bigint; v_transfer uuid; v_claim uuid;
  v_result uuid[]:='{}'; v_existing_count int;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_request_id is null then raise exception 'Request id required' using errcode='22023'; end if;
  v_count:=coalesce(array_length(p_creditor_user_ids,1),0);
  if v_count<1 or v_count>30 or v_count<>coalesce(array_length(p_amounts_paisa,1),0) then
    raise exception 'Choose 1–30 recipients with amounts' using errcode='22023'; end if;
  if p_round_up is null then raise exception 'Select rounding preference' using errcode='22023'; end if;
  select * into v_group from public.groups where id=p_group_id for update;
  if not found or v_group.archived_at is not null then
    raise exception 'Group missing or archived' using errcode='22023'; end if;
  if not exists(select 1 from public.group_members where group_id=p_group_id and user_id=v_actor and left_at is null) then
    raise exception 'Not an active group member' using errcode='42501'; end if;
  v_month:=date_trunc('month',now() at time zone v_group.timezone)::date;
  if exists(select 1 from public.settlement_periods where group_id=p_group_id and period_month=v_month) then
    raise exception 'This month is already closed' using errcode='22023'; end if;
  select count(*) into v_existing_count from public.settlement_transfers
    where group_id=p_group_id and debtor_user_id=v_actor and source='early' and early_batch_id=p_request_id;
  if v_existing_count > 0 then
    if v_existing_count<>v_count then raise exception 'Request key already used' using errcode='22023'; end if;
    for v_i in 1..v_count loop
      select c.id into v_claim from public.settlement_transfers t
        join public.settlement_payment_claims c on c.transfer_id=t.id
      where t.group_id=p_group_id and t.debtor_user_id=v_actor and t.source='early'
        and t.early_batch_id=p_request_id and t.creditor_user_id=p_creditor_user_ids[v_i]
        and t.amount_paisa=p_amounts_paisa[v_i]
      order by c.created_at limit 1;
      if v_claim is null then raise exception 'Request id reused with different details' using errcode='22023'; end if;
      v_result:=array_append(v_result,v_claim);
    end loop;
    return v_result;
  end if;
  if (select count(distinct u) from unnest(p_creditor_user_ids) u)<>v_count then
    raise exception 'Duplicate recipients' using errcode='22023'; end if;
  for v_i in 1..v_count loop
    if p_creditor_user_ids[v_i] is null or p_amounts_paisa[v_i] is null or p_amounts_paisa[v_i]<=0 then
      raise exception 'Invalid recipient or amount' using errcode='22023'; end if;
    select s.amount_paisa into v_expected from app_private.open_month_suggestions(p_group_id) s
      where s.debtor_user_id=v_actor and s.creditor_user_id=p_creditor_user_ids[v_i];
    if v_expected is null or p_amounts_paisa[v_i]>v_expected then
      raise exception 'Balance changed; refresh before submitting' using errcode='22023'; end if;
  end loop;
  for v_i in 1..v_count loop
    v_paid:=case when p_round_up then ((p_amounts_paisa[v_i]+99)/100)*100 else p_amounts_paisa[v_i] end;
    insert into public.settlement_transfers(
      period_id,group_id,debtor_user_id,creditor_user_id,amount_paisa,status,source,origin_month,early_batch_id
    ) values(null,p_group_id,v_actor,p_creditor_user_ids[v_i],p_amounts_paisa[v_i],
      'awaiting_confirmation','early',v_month,p_request_id) returning id into v_transfer;
    insert into public.settlement_payment_claims(
      transfer_id,claimed_by_user_id,actual_paid_paisa,applied_paisa,rounding_adjustment_paisa,request_id
    ) values(v_transfer,v_actor,v_paid,p_amounts_paisa[v_i],v_paid-p_amounts_paisa[v_i],p_request_id)
    returning id into v_claim;
    v_result:=array_append(v_result,v_claim);
    insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
      values(p_creditor_user_ids[v_i],p_group_id,'payment:'||v_claim||':claimed',
        'payment_claimed','Early chai payment reported',
        'A colleague reported an early payment. Confirm receipt in Settlements.',
        'settlement_transfer',v_transfer)
      on conflict(recipient_user_id,event_key) do nothing;
  end loop;
  return v_result;
end $$;

-- Keep all-time dashboard/group balances consistent with partial confirmations.
-- Previously it only counted transfers whose status was entirely confirmed.
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
   select c.user_id uid,sum(c.amount_paisa)::bigint amount from public.expense_contributions c
   join public.expenses e on e.id=c.expense_id
   where e.group_id=p_group_id and e.voided_at is null group by c.user_id
 ), consumed as (
   select s.user_id uid,sum(s.share_paisa)::bigint amount from public.expense_shares s
   join public.expenses e on e.id=s.expense_id
   where e.group_id=p_group_id and e.voided_at is null group by s.user_id
 ), confirmed_out as (
   select t.debtor_user_id uid,sum(t.applied_paisa)::bigint amount from public.settlement_transfers t
   where t.group_id=p_group_id and t.applied_paisa>0 group by t.debtor_user_id
 ), confirmed_in as (
   select t.creditor_user_id uid,sum(t.applied_paisa)::bigint amount from public.settlement_transfers t
   where t.group_id=p_group_id and t.applied_paisa>0 group by t.creditor_user_id
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


-- Month-specific session explanations (no charging individual shares).
create function app_private.my_month_session_details(p_group_id uuid,p_month date)
returns table(expense_id uuid, occurred_at timestamptz, description text,
  bill_paisa bigint, my_share_paisa bigint, my_contribution_paisa bigint)
language plpgsql stable security definer set search_path='' as $$
declare v_tz text;
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode='42501'; end if;
  if p_month is null or extract(day from p_month)<>1 then
    raise exception 'Month must start on the first day' using errcode='22023'; end if;
  if not exists(select 1 from public.group_members
    where group_id=p_group_id and user_id=auth.uid() and left_at is null) then
    raise exception 'Not an active group member' using errcode='42501'; end if;
  select timezone into v_tz from public.groups where id=p_group_id;
  if v_tz is null then raise exception 'Group missing' using errcode='22023'; end if;
  return query select e.id,e.occurred_at,e.description,e.amount_paisa,coalesce(s.share_paisa,0)::bigint,
    coalesce((select sum(c.amount_paisa)::bigint from public.expense_contributions c
      where c.expense_id=e.id and c.user_id=auth.uid()),0)::bigint
    from public.expenses e left join public.expense_shares s
      on s.expense_id=e.id and s.user_id=auth.uid()
    where e.group_id=p_group_id and e.voided_at is null
      and (s.user_id is not null or exists(select 1 from public.expense_contributions c
        where c.expense_id=e.id and c.user_id=auth.uid()))
      and date_trunc('month',e.occurred_at at time zone v_tz)::date=p_month
    order by e.occurred_at desc, e.id desc;
end $$;
create function public.my_month_session_details(p_group_id uuid,p_month date)
returns table(expense_id uuid, occurred_at timestamptz, description text,
  bill_paisa bigint, my_share_paisa bigint, my_contribution_paisa bigint)
language sql security invoker set search_path='' as $$
  select * from app_private.my_month_session_details(p_group_id,p_month);
$$;
revoke all on function app_private.my_month_session_details(uuid,date) from public,anon,authenticated;
grant execute on function app_private.my_month_session_details(uuid,date) to authenticated;
revoke all on function public.my_month_session_details(uuid,date) from public,anon,authenticated;
grant execute on function public.my_month_session_details(uuid,date) to authenticated;

-- Backward-compatibility safety check: claims of fully settled transfers must
-- account for the original entire obligation after migration.
do $$ begin
 if exists(select 1 from public.settlement_transfers where status='confirmed' and applied_paisa<>amount_paisa) then
    raise exception 'Confirmed transfer inconsistent after backfill'; end if;
end $$;

commit;
