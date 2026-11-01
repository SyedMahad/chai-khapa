-- LOCAL SUPABASE ONLY. NEVER run this script in production.
-- Requires all migrations through multi-contributor Phase 3.8.
-- Run as privileged local postgres with ON_ERROR_STOP=1. All writes roll back.
begin;
insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,
 raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
 ('00000000-0000-4000-8000-000000003801','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p38a@example.invalid',now(),'{}','{}',now(),now()),
 ('00000000-0000-4000-8000-000000003802','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p38b@example.invalid',now(),'{}','{}',now(),now()),
 ('00000000-0000-4000-8000-000000003803','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p38c@example.invalid',now(),'{}','{}',now(),now()),
 ('00000000-0000-4000-8000-000000003804','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p38d@example.invalid',now(),'{}','{}',now(),now());
set local role authenticated;
create temp table state38 (key text primary key,val text) on commit drop;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003801',true);
select public.complete_profile('Alpha','Contributor');
insert into state38 values ('group',public.create_group('Phase 38 test group')::text);
insert into state38 values ('token', (public.create_group_invite((select val::uuid from state38 where key='group'),4,24))->>'token');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003802',true);
select public.complete_profile('Bravo','Contributor');
select public.join_group((select val from state38 where key='token'));
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003803',true);
select public.complete_profile('Charlie','Contributor');
select public.join_group((select val from state38 where key='token'));
-- D joins but will NOT attend; may still contribute.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003804',true);
select public.complete_profile('Delta','Contributor');
select public.join_group((select val from state38 where key='token'));
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003801',true);
insert into state38 values ('multi_expense',public.record_expense_multi(
 (select val::uuid from state38 where key='group'),400000,
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid,'00000000-0000-4000-8000-000000003803'::uuid],
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid,'00000000-0000-4000-8000-000000003804'::uuid],
 array[200000::bigint,130000::bigint,70000::bigint],
 '00000000-0000-4000-8000-0000000038aa'::uuid,'4000 rupees dinner',null)::text);
-- Same request is idempotent; even with contributor ordering changed.
do $$ declare v_id uuid; v_group uuid;begin
 select val::uuid into v_group from state38 where key='group';
 v_id:=public.record_expense_multi(v_group,400000,
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid,'00000000-0000-4000-8000-000000003803'::uuid],
 array['00000000-0000-4000-8000-000000003804'::uuid,'00000000-0000-4000-8000-000000003802'::uuid,'00000000-0000-4000-8000-000000003801'::uuid],
 array[70000::bigint,130000::bigint,200000::bigint],
 '00000000-0000-4000-8000-0000000038aa'::uuid,'4000 rupees dinner',null);
 if v_id is distinct from (select val::uuid from state38 where key='multi_expense') then raise exception 'Idempotency failed';end if;
end $$;
-- Bad totals rejected.
do $$begin
 begin
 perform public.record_expense_multi((select val::uuid from state38 where key='group'),10000,
 array['00000000-0000-4000-8000-000000003801'::uuid],
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid],
 array[9000::bigint,900::bigint],gen_random_uuid());
 raise exception 'Invalid contribution total unexpectedly accepted';
 exception when sqlstate '22023' then null;end;
end $$;
-- Original legacy RPC still saves a one-contributor expense.
insert into state38 values ('legacy_expense',public.record_expense(
 (select val::uuid from state38 where key='group'),10000,
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid],
 gen_random_uuid(),'Legacy single payer',null)::text);
do $$ declare v_group uuid; v_sum bigint; v_total bigint; v_d_paid bigint; v_b_paid bigint;begin
 select val::uuid into v_group from state38 where key='group';
 select sum(c.amount_paisa) into v_sum from public.expense_contributions c
  where c.expense_id=(select val::uuid from state38 where key='multi_expense');
 if v_sum<>400000 then raise exception 'Multi contribution sum mismatch %',v_sum;end if;
 select count(*) into v_total from public.expense_contributions c
  where c.expense_id=(select val::uuid from state38 where key='legacy_expense');
 if v_total<>1 then raise exception 'Legacy writer produced wrong contributors';end if;
 select b.total_paid_paisa into v_d_paid from public.get_group_balances(v_group) b
  where b.user_id='00000000-0000-4000-8000-000000003804'::uuid;
 if v_d_paid<>70000 then raise exception 'Non-attendee contribution not counted';end if;
 select b.total_paid_paisa into v_b_paid from public.get_group_balances(v_group) b
  where b.user_id='00000000-0000-4000-8000-000000003802'::uuid;
 if v_b_paid<>130000 then raise exception 'Second contributor credit mismatch %',v_b_paid;end if;
 if (select sum(b.net_paisa) from public.get_group_balances(v_group) b)<>0 then
  raise exception 'Ledger does not net to zero';end if;
end $$;
-- Historical month-end netting must credit the contributor, not only the legacy payer.
-- Last instant of previous month falls within the writer's 31-day lookback.
insert into state38 values ('last_expense',public.record_expense_multi(
 (select val::uuid from state38 where key='group'),30000,
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid,'00000000-0000-4000-8000-000000003803'::uuid],
 array['00000000-0000-4000-8000-000000003801'::uuid,'00000000-0000-4000-8000-000000003802'::uuid],
 array[20000::bigint,10000::bigint],gen_random_uuid(),'Last month split funding',
 ((date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 second') at time zone 'Asia/Karachi'))::text);
insert into state38 values ('closed_period',public.close_settlement_month(
 (select val::uuid from state38 where key='group'),
 (date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 month')::date)::text);
do $$declare v_total bigint;v_sender uuid;v_recipient uuid;begin
 select sum(t.amount_paisa), min(t.debtor_user_id), min(t.creditor_user_id)
 into v_total,v_sender,v_recipient from public.settlement_transfers t
 where t.period_id=(select val::uuid from state38 where key='closed_period');
 if v_total<>10000 or v_sender<>'00000000-0000-4000-8000-000000003803'::uuid
   or v_recipient<>'00000000-0000-4000-8000-000000003801'::uuid then
   raise exception 'Month close ignored multi-contributor ledger: %,%,%',v_total,v_sender,v_recipient;
 end if;
end $$;
-- Unauthorised outsider cannot read contributions or call the writer.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003899',true);
do $$declare v_group uuid;begin
 select val::uuid into v_group from state38 where key='group';
 if exists(select 1 from public.expense_contributions c where c.group_id=v_group) then
  raise exception 'Outside user could read contributions';end if;
 begin
  perform public.record_expense_multi(v_group,100,
   array['00000000-0000-4000-8000-000000003801'::uuid],
   array['00000000-0000-4000-8000-000000003801'::uuid],
   array[100::bigint],gen_random_uuid());
  raise exception 'Outside user wrote an expense';
 exception when insufficient_privilege then null;end;
end $$;
select 'PASS: Multi-contributor local tests (all rolled back)' as result;
rollback;
