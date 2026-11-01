-- LOCAL SUPABASE ONLY. Creates synthetic auth users; NEVER RUN ON PRODUCTION.
-- Entire test rolls back (including fake accounts).
begin;
insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('00000000-0000-4000-8000-000000003901','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p39-a@example.invalid',now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-000000003902','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p39-b@example.invalid',now(),'{}','{}',now(),now());
set local role authenticated;
create temporary table ck39_ids (k text primary key, v text) on commit drop;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.complete_profile('P39','Creditor');
insert into ck39_ids values('group',public.create_group('P39 Local')::text);
insert into ck39_ids values ('invite',(public.create_group_invite((select v::uuid from ck39_ids where k='group'),2,24))->>'token');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003902',true);
select public.complete_profile('P39','Debtor');
select public.join_group((select v from ck39_ids where k='invite'));
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
-- Previous month: A paid Rs 100 for A and B; B owes Rs 50 net.
select public.record_expense((select v::uuid from ck39_ids where k='group'),10000,
 array['00000000-0000-4000-8000-000000003901'::uuid,'00000000-0000-4000-8000-000000003902'::uuid],
 gen_random_uuid(),'P39 previous month',
 ((date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 second') at time zone 'Asia/Karachi'));
insert into ck39_ids values('period',public.close_settlement_month(
 (select v::uuid from ck39_ids where k='group'),
 (date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 month')::date)::text);
insert into ck39_ids select 'transfer',t.id::text from public.settlement_transfers t
 where t.period_id=(select v::uuid from ck39_ids where k='period');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003902',true);
insert into ck39_ids values('batch',gen_random_uuid()::text);
insert into ck39_ids values('claim1',(public.claim_month_payments(
 array[(select v::uuid from ck39_ids where k='transfer')], array[2000::bigint],
 (select v::uuid from ck39_ids where k='batch'),false))[1]::text);
-- Same request is idempotent, even after a retry.
do $$ begin
 if (public.claim_month_payments(array[(select v::uuid from ck39_ids where k='transfer')],
  array[2000::bigint],(select v::uuid from ck39_ids where k='batch'),false))[1]
  is distinct from (select v::uuid from ck39_ids where k='claim1') then
  raise exception 'Duplicate payment claim created'; end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.confirm_transfer_payment((select v::uuid from ck39_ids where k='claim1'),true);
do $$ declare t public.settlement_transfers%rowtype; v_net bigint; begin
 select * into t from public.settlement_transfers where id=(select v::uuid from ck39_ids where k='transfer');
 if t.applied_paisa <> 2000 or t.status <> 'unpaid' then raise exception 'Partial confirmation failed'; end if;
 select net_paisa into v_net from public.get_group_balances((select v::uuid from ck39_ids where k='group'))
  where user_id='00000000-0000-4000-8000-000000003902'::uuid;
 if v_net <> -3000 then raise exception 'Running balance did not count partial receipt: %',v_net; end if;
end $$;
-- Second partial, then rejection must not affect the amount already paid.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003902',true);
insert into ck39_ids values('claim2',(public.claim_month_payments(
 array[(select v::uuid from ck39_ids where k='transfer')],array[3000::bigint],gen_random_uuid(),false))[1]::text);
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.confirm_transfer_payment((select v::uuid from ck39_ids where k='claim2'),false);
do $$ begin
 if (select applied_paisa from public.settlement_transfers where id=(select v::uuid from ck39_ids where k='transfer'))<>2000 then
   raise exception 'Rejection changed confirmed amount';end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003902',true);
insert into ck39_ids values('claim3',(public.claim_month_payments(
 array[(select v::uuid from ck39_ids where k='transfer')],array[3000::bigint],gen_random_uuid(),false))[1]::text);
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.confirm_transfer_payment((select v::uuid from ck39_ids where k='claim3'),true);
do $$ begin
 if not exists(select 1 from public.settlement_transfers
   where id=(select v::uuid from ck39_ids where k='transfer') and status='confirmed' and applied_paisa=amount_paisa)
 then raise exception 'Final confirmation did not settle the transfer'; end if;
end $$;
-- Current-month suggestion: select and pay only Rs 20 of Rs 50 net.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.record_expense((select v::uuid from ck39_ids where k='group'),10000,
 array['00000000-0000-4000-8000-000000003901'::uuid,'00000000-0000-4000-8000-000000003902'::uuid],
 gen_random_uuid(),'P39 current month',null);
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003902',true);
insert into ck39_ids values('earlyClaim',(public.claim_early_settlements(
 (select v::uuid from ck39_ids where k='group'),
 array['00000000-0000-4000-8000-000000003901'::uuid],array[2000::bigint],gen_random_uuid(),false))[1]::text);
do $$ declare v_left bigint; begin
 select amount_paisa into v_left from public.get_open_month_suggestions((select v::uuid from ck39_ids where k='group'))
  where debtor_user_id='00000000-0000-4000-8000-000000003902'::uuid
    and creditor_user_id='00000000-0000-4000-8000-000000003901'::uuid;
 if v_left <> 3000 then raise exception 'Open-month partial early reservation did not leave Rs 30: %',v_left; end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003901',true);
select public.confirm_transfer_payment((select v::uuid from ck39_ids where k='earlyClaim'),true);
do $$ declare v_net bigint; begin
 select b.net_paisa into v_net from public.get_group_balances((select v::uuid from ck39_ids where k='group')) b
   where b.user_id='00000000-0000-4000-8000-000000003902'::uuid;
 if v_net <> -3000 then raise exception 'Wrong net after current partial and previous full payments: %',v_net; end if;
end $$;
select 'PASS — partial confirmation, rejection, retry, exact balance; rolling back' as local_test_result;
rollback;
