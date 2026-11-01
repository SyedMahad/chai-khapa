-- Chai Khapa | Multi-contributor expense ledger
-- Apply AFTER Phase 3.7.1. Back up production first. No historical settlement rewriting.
-- Single-payer legacy API remains available and writes to the same contribution ledger.
begin;

-- Reject accidental rerun if unexpected broken data exist before backfilling.
do $$ begin
 if exists (select 1 from public.expenses where paid_by_user_id is null) then
   raise exception 'Legacy expense has no payer. Stop and inspect.';
 end if;
end $$;

create table public.expense_contributions (
 expense_id uuid not null,
 group_id uuid not null,
 user_id uuid not null,
 amount_paisa bigint not null check (amount_paisa > 0),
 primary key(expense_id,user_id),
 constraint expense_contributions_expense_fk foreign key(expense_id,group_id)
   references public.expenses(id,group_id) on delete restrict,
 constraint expense_contributions_member_fk foreign key(group_id,user_id)
   references public.group_members(group_id,user_id) on delete restrict
);
create index expense_contributions_user_idx
 on public.expense_contributions(group_id,user_id,expense_id);

-- Every old one-payer expense becomes an identical one-contributor expense.
insert into public.expense_contributions(expense_id,group_id,user_id,amount_paisa)
 select e.id,e.group_id,e.paid_by_user_id,e.amount_paisa from public.expenses e;

do $$ begin
 if exists (select 1 from public.expenses e left join (
   select expense_id,sum(amount_paisa)::numeric total from public.expense_contributions group by expense_id
 ) c on c.expense_id=e.id where c.total is distinct from e.amount_paisa::numeric) then
   raise exception 'Contribution backfill mismatch; rollback';
 end if;
end $$;

-- New ledger is group-readable, NEVER directly writable from the browser.
alter table public.expense_contributions enable row level security;
revoke all on public.expense_contributions from public,anon,authenticated;
grant select on public.expense_contributions to authenticated;
create policy contributions_visible_to_active_group
 on public.expense_contributions for select to authenticated
 using(group_id in (select app_private.my_active_group_ids()));

-- Deferred constraint ensures no privileged path may commit a partially funded bill.
-- Atomic RPCs write expense then all contributions inside the same transaction.
create function app_private.assert_expense_fully_funded()
 returns trigger language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_total numeric; v_expected bigint;
begin
 v_id:=case when tg_op='DELETE' then old.expense_id
            when tg_table_name='expenses' then new.id else new.expense_id end;
 select e.amount_paisa into v_expected from public.expenses e where e.id=v_id;
 if v_expected is null then return null; end if;
 select coalesce(sum(c.amount_paisa),0)::numeric into v_total
   from public.expense_contributions c where c.expense_id=v_id;
 if v_total<>v_expected::numeric then
   raise exception 'Expense % contributions total % must equal bill %',v_id,v_total,v_expected
     using errcode='23514';
 end if;
 return null;
end $$;
create constraint trigger expense_funding_after_expense
 after insert or update on public.expenses
 deferrable initially deferred for each row
 execute function app_private.assert_expense_fully_funded();
create constraint trigger expense_funding_after_contribution
 after insert or update or delete on public.expense_contributions
 deferrable initially deferred for each row
 execute function app_private.assert_expense_fully_funded();
revoke all on function app_private.assert_expense_fully_funded() from public,anon,authenticated;

-- New canonical writer. Contributions and consumption are separate concepts.
create function app_private.record_expense_multi(
 p_group_id uuid,p_amount_paisa bigint,p_participant_user_ids uuid[],
 p_contributor_user_ids uuid[],p_contribution_amounts_paisa bigint[],
 p_request_id uuid,p_description text default null,p_occurred_at timestamptz default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare
 v_actor uuid:=auth.uid(); v_group public.groups%rowtype; v_expense_id uuid;
 v_existing public.expenses%rowtype; v_occurs timestamptz:=coalesce(p_occurred_at,now());
 v_desc text:=nullif(btrim(p_description),'');
 v_n int; v_cn int; v_member_count int; v_contributor_count int;
 v_primary uuid; v_name text;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_group_id is null or p_request_id is null or p_amount_paisa is null or p_amount_paisa<=0 then
   raise exception 'Group, positive bill and request ID required' using errcode='22023'; end if;
 if v_desc is not null and char_length(v_desc)>240 then
   raise exception 'Session description too long' using errcode='22023'; end if;
 if v_occurs>now()+interval '5 minutes' or v_occurs<now()-interval '31 days' then
   raise exception 'Session date must be within 31 days and not future' using errcode='22023'; end if;

 -- Serializes writes with month closing and concurrent attempts to use one request ID.
 select * into v_group from public.groups where id=p_group_id for update;
 if not found or v_group.archived_at is not null then
   raise exception 'Group missing or archived' using errcode='22023'; end if;
 if not exists (select 1 from public.group_members gm where gm.group_id=p_group_id
   and gm.user_id=v_actor and gm.left_at is null) then
   raise exception 'Only active group members may record expenses' using errcode='42501'; end if;

 v_n:=coalesce(cardinality(p_participant_user_ids),0);
 v_cn:=coalesce(cardinality(p_contributor_user_ids),0);
 if v_n<1 or v_cn<1 or v_n>100 or v_cn>100
    or v_cn<>coalesce(cardinality(p_contribution_amounts_paisa),0) then
   raise exception 'Select attendees and 1–100 contributors with matching amounts' using errcode='22023'; end if;
 if exists(select 1 from unnest(p_participant_user_ids) a(id) where a.id is null)
    or (select count(distinct a.id) from unnest(p_participant_user_ids) a(id))<>v_n
    or exists(select 1 from unnest(p_contributor_user_ids) a(id) where a.id is null)
    or (select count(distinct a.id) from unnest(p_contributor_user_ids) a(id))<>v_cn then
   raise exception 'Attendees and contributors must be unique valid users' using errcode='22023'; end if;
 if exists(select 1 from unnest(p_contribution_amounts_paisa) a(amount) where a.amount is null or a.amount<=0)
    or (select coalesce(sum(a.amount),0) from unnest(p_contribution_amounts_paisa) a(amount))<>p_amount_paisa::numeric then
   raise exception 'Contributions must be positive and equal the full bill' using errcode='22023'; end if;
 select count(*) into v_member_count from public.group_members gm
   where gm.group_id=p_group_id and gm.left_at is null and gm.user_id=any(p_participant_user_ids);
 select count(*) into v_contributor_count from public.group_members gm
   where gm.group_id=p_group_id and gm.left_at is null and gm.user_id=any(p_contributor_user_ids);
 if v_member_count<>v_n or v_contributor_count<>v_cn then
   raise exception 'Every attendee and contributor must be an active group member' using errcode='22023'; end if;

 v_primary:=case when v_actor=any(p_contributor_user_ids) then v_actor
  else (select min(c.user_id) from unnest(p_contributor_user_ids) c(user_id)) end;
 select * into v_existing from public.expenses e where e.created_by_user_id=v_actor and e.request_id=p_request_id;
 if found then
   if v_existing.group_id<>p_group_id or v_existing.amount_paisa<>p_amount_paisa
      or v_existing.paid_by_user_id<>v_primary or v_existing.description is distinct from v_desc
      or (p_occurred_at is not null and v_existing.occurred_at<>p_occurred_at)
      or v_existing.voided_at is not null
      or (select array_agg(s.user_id order by s.user_id) from public.expense_shares s where s.expense_id=v_existing.id)
         is distinct from (select array_agg(u.user_id order by u.user_id) from unnest(p_participant_user_ids) u(user_id))
      or (select jsonb_agg(jsonb_build_array(c.user_id,c.amount_paisa) order by c.user_id)
         from public.expense_contributions c where c.expense_id=v_existing.id)
         is distinct from (select jsonb_agg(jsonb_build_array(u.user_id,u.amount) order by u.user_id)
         from unnest(p_contributor_user_ids,p_contribution_amounts_paisa) u(user_id,amount)) then
       raise exception 'Request ID already used for a different bill' using errcode='23505'; end if;
   return v_existing.id;
 end if;

 -- Already saved retries remain valid after a month is closed.
 if exists (select 1 from public.settlement_periods sp where sp.group_id=p_group_id
  and v_occurs>=sp.start_at and v_occurs<sp.end_at) then
   raise exception 'This accounting month is closed' using errcode='22023'; end if;

 insert into public.expenses(group_id,created_by_user_id,paid_by_user_id,amount_paisa,
  split_method,occurred_at,description,request_id)
 values(p_group_id,v_actor,v_primary,p_amount_paisa,'equal',v_occurs,v_desc,p_request_id)
 returning id into v_expense_id;

 insert into public.expense_contributions(expense_id,group_id,user_id,amount_paisa)
 select v_expense_id,p_group_id,u.user_id,u.amount
 from unnest(p_contributor_user_ids,p_contribution_amounts_paisa) u(user_id,amount);
 insert into public.expense_shares(expense_id,group_id,user_id,share_paisa)
 select v_expense_id,p_group_id,u.user_id,
   (p_amount_paisa/v_n)::bigint + case when u.ordinal<=(p_amount_paisa%v_n) then 1 else 0 end
 from (select p.user_id,row_number() over(order by p.user_id) ordinal
   from unnest(p_participant_user_ids) p(user_id)) u;

 insert into public.expense_audit(expense_id,group_id,actor_user_id,operation,after_json)
 values(v_expense_id,p_group_id,v_actor,'created',jsonb_build_object(
  'amount_paisa',p_amount_paisa,'occurred_at',v_occurs,'split_method','equal',
  'participants',(select jsonb_agg(jsonb_build_object('user_id',s.user_id,'share_paisa',s.share_paisa) order by s.user_id)
    from public.expense_shares s where s.expense_id=v_expense_id),
  'contributors',(select jsonb_agg(jsonb_build_object('user_id',c.user_id,'amount_paisa',c.amount_paisa) order by c.user_id)
    from public.expense_contributions c where c.expense_id=v_expense_id)));

 select coalesce(nullif(btrim(p.first_name||' '||p.last_name),''),'A colleague')
   into v_name from public.profiles p where p.user_id=v_actor;
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 select s.user_id,p_group_id,'expense:'||v_expense_id::text||':created',
   'expense_created','New chai session',
   coalesce(v_name,'A colleague')||' recorded a session. Your share: Rs. '
    ||(s.share_paisa/100)::text||'.'||lpad((s.share_paisa%100)::text,2,'0')||'.',
   'expense',v_expense_id
 from public.expense_shares s where s.expense_id=v_expense_id and s.user_id<>v_actor
 on conflict(recipient_user_id,event_key) do nothing;
 -- Include contributors who weren't attendees, so they can see their credited contribution.
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 select c.user_id,p_group_id,'expense:'||v_expense_id::text||':contributed',
   'expense_created','Your contribution was recorded',
   coalesce(v_name,'A colleague')||' recorded your contribution of Rs. '
    ||(c.amount_paisa/100)::text||'.'||lpad((c.amount_paisa%100)::text,2,'0')||'.',
   'expense',v_expense_id
 from public.expense_contributions c where c.expense_id=v_expense_id and c.user_id<>v_actor
   and not exists (select 1 from public.expense_shares s where s.expense_id=v_expense_id and s.user_id=c.user_id)
 on conflict(recipient_user_id,event_key) do nothing;
 return v_expense_id;
end $$;

-- Browser RPC has only an invoker wrapper. No client table write privileges.
create function public.record_expense_multi(
 p_group_id uuid,p_amount_paisa bigint,p_participant_user_ids uuid[],
 p_contributor_user_ids uuid[],p_contribution_amounts_paisa bigint[],
 p_request_id uuid,p_description text default null,p_occurred_at timestamptz default null
) returns uuid language sql security invoker set search_path='' as $$
 select app_private.record_expense_multi(p_group_id,p_amount_paisa,p_participant_user_ids,
  p_contributor_user_ids,p_contribution_amounts_paisa,p_request_id,p_description,p_occurred_at)
$$;

-- Compatibility for old app builds: they still record a one-person contribution.
create or replace function app_private.record_expense(
 p_group_id uuid,p_amount_paisa bigint,p_participant_user_ids uuid[],p_request_id uuid,
 p_description text default null,p_occurred_at timestamptz default null
) returns uuid language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not (auth.uid()=any(p_participant_user_ids)) then
   raise exception 'Original payer must be among attendees for legacy recorder' using errcode='22023'; end if;
 return app_private.record_expense_multi(p_group_id,p_amount_paisa,p_participant_user_ids,
   array[auth.uid()],array[p_amount_paisa],p_request_id,p_description,p_occurred_at);
end $$;
revoke all on function app_private.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)
 from public,anon,authenticated;
grant execute on function app_private.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)
 to authenticated;
revoke all on function public.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)
 from public,anon,authenticated;
grant execute on function public.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)
 to authenticated;

-- All ledger readers must use actual contributions, not legacy paid_by_user_id.
-- Existing periods and confirmed settlement claims are preserved as-is.

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

create or replace function app_private.close_settlement_month_core(p_group_id uuid, p_month date, p_actor_id uuid, p_auto boolean)
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
    select c.user_id uid, sum(c.amount_paisa)::bigint amt
    from public.expense_contributions c join public.expenses e on e.id=c.expense_id
    where e.group_id=p_group_id and e.voided_at is null and e.occurred_at>=v_start and e.occurred_at<v_end
    group by c.user_id
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

create or replace function app_private.open_month_suggestions(p_group_id uuid)
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
      select c.user_id uid,sum(c.amount_paisa)::bigint amt
      from public.expense_contributions c join public.expenses e on e.id=c.expense_id
      where e.group_id=p_group_id and e.voided_at is null and e.occurred_at>=v_start and e.occurred_at<v_end
      group by c.user_id
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

-- Fail migration instead of silently changing historical payer credits or bill totals.
do $$ begin
 if exists (
  select 1 from public.expenses e
  left join (select expense_id,sum(amount_paisa) s from public.expense_contributions group by expense_id) c
    on c.expense_id=e.id
  where c.s is distinct from e.amount_paisa::numeric
 ) then raise exception 'Some expense contributions do not equal their bill amount'; end if;
end $$;
commit;
