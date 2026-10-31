-- Local Supabase ONLY; must run as postgres with ability to SET ROLE.
-- ALL changes rolled back; never execute on your production project.
begin;
insert into auth.users(id, instance_id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at,updated_at) values
('00000000-0000-4000-8000-00000000c601','00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','ck36-a@example.invalid',now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-00000000c602','00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','ck36-b@example.invalid',now(),'{}','{}',now(),now());
set local role authenticated;
create temp table ck36_state(k text primary key,v text) on commit drop;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-00000000c601',true);
select public.complete_profile('Owner','Tester');
insert into ck36_state values ('group',public.create_group('Monthly Chai Tests')::text);
insert into ck36_state values ('token',(public.create_group_invite((select v::uuid from ck36_state where k='group'),2,24))->>'token');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-00000000c602',true);
select public.complete_profile('Member','Tester');
select public.join_group((select v from ck36_state where k='token'));
-- Owner paid Rs 100.00 for two people during the last completed local month.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-00000000c601',true);
insert into ck36_state values ('expense',public.record_expense(
 (select v::uuid from ck36_state where k='group'),10000,
 array['00000000-0000-4000-8000-00000000c601'::uuid,'00000000-0000-4000-8000-00000000c602'::uuid],
 gen_random_uuid(), 'Backdated chai session',
 ((date_trunc('month',now() at time zone 'Asia/Karachi') - interval '1 second') at time zone 'Asia/Karachi')
)::text);
insert into ck36_state values ('period',public.close_settlement_month(
 (select v::uuid from ck36_state where k='group'),
 (date_trunc('month',now() at time zone 'Asia/Karachi') - interval '1 month')::date
)::text);
-- Closure idempotency and one transfer to owner.
do $$ declare v_group uuid; v_period uuid; begin
 select v::uuid into v_group from ck36_state where k='group';
 select v::uuid into v_period from ck36_state where k='period';
 if public.close_settlement_month(v_group,(date_trunc('month',now() at time zone 'Asia/Karachi') - interval '1 month')::date) <> v_period then
  raise exception 'Month-close idempotency failed'; end if;
 if (select count(*) from public.settlement_transfers where period_id=v_period and amount_paisa=5000)<>1 then
  raise exception 'Wrong month settlement transfer'; end if;
end $$;
-- Debtor marks paid; creditor confirms; net becomes zero.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-00000000c602',true);
insert into ck36_state values ('transfer',(select id::text from public.settlement_transfers where period_id=(select v::uuid from ck36_state where k='period')));
insert into ck36_state values ('claim',public.mark_transfer_paid((select v::uuid from ck36_state where k='transfer'),5000)::text);
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-00000000c601',true);
select public.confirm_transfer_payment((select v::uuid from ck36_state where k='claim'),true);
do $$ declare v_net bigint; begin
 select net_paisa into v_net from public.get_group_balances((select v::uuid from ck36_state where k='group'))
 where user_id='00000000-0000-4000-8000-00000000c601'::uuid;
 if v_net<>0 then raise exception 'Confirmed payment did not reset net: %',v_net; end if;
end $$;
select 'PASS: local settlement smoke test, rolling back' as result;
rollback;
