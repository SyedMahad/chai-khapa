-- LOCAL SUPABASE ONLY. NEVER RUN AGAINST PRODUCTION.
-- This test creates fake auth accounts. All changes are rolled back.
begin;

insert into auth.users(id,instance_id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('00000000-0000-4000-8000-000000003701','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p37-owner@example.invalid',now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-000000003702','00000000-0000-0000-0000-000000000000','authenticated','authenticated','p37-debtor@example.invalid',now(),'{}','{}',now(),now());

set local role authenticated;
create temporary table ck37_ids (key text primary key, val text) on commit drop;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003701',true);
select public.complete_profile('Owner','Tester');
insert into ck37_ids values ('group',public.create_group('Phase 37 Test')::text);
insert into ck37_ids values ('invite',(
  public.create_group_invite((select val::uuid from ck37_ids where key='group'),2,24))->>'token');
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003702',true);
select public.complete_profile('Debtor','Tester');
select public.join_group((select val from ck37_ids where key='invite'));

-- Owner paid Rs 100 this month; debtor owes Rs 50.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003701',true);
select public.record_expense((select val::uuid from ck37_ids where key='group'),10000,
 array['00000000-0000-4000-8000-000000003701'::uuid,'00000000-0000-4000-8000-000000003702'::uuid],
 gen_random_uuid(),'Current-month chai',null);

select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003702',true);
do $$ declare v_amount bigint; begin
  select s.amount_paisa into v_amount from public.get_open_month_suggestions(
    (select val::uuid from ck37_ids where key='group')) s
  where s.debtor_user_id='00000000-0000-4000-8000-000000003702'::uuid
    and s.creditor_user_id='00000000-0000-4000-8000-000000003701'::uuid;
  if v_amount is distinct from 5000 then raise exception 'Expected 5000 paisa due; got %',v_amount; end if;
end $$;

insert into ck37_ids values ('batch',gen_random_uuid()::text);
insert into ck37_ids values ('claim',(
  public.claim_early_settlements((select val::uuid from ck37_ids where key='group'),
   array['00000000-0000-4000-8000-000000003701'::uuid],
   array[5000::bigint],(select val::uuid from ck37_ids where key='batch'),true))[1]::text);
-- Repeated request id is idempotent.
do $$ declare v_claim uuid; begin
 v_claim := (public.claim_early_settlements((select val::uuid from ck37_ids where key='group'),
   array['00000000-0000-4000-8000-000000003701'::uuid],
   array[5000::bigint],(select val::uuid from ck37_ids where key='batch'),true))[1];
 if v_claim is distinct from (select val::uuid from ck37_ids where key='claim') then
    raise exception 'Early claim idempotency failed'; end if;
 if exists(select 1 from public.get_open_month_suggestions((select val::uuid from ck37_ids where key='group'))
   where debtor_user_id='00000000-0000-4000-8000-000000003702'::uuid) then
   raise exception 'Awaiting claim has not reserved its liability'; end if;
end $$;

-- Debtor cannot self-confirm. Recipient must decide.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000003701',true);
select public.confirm_transfer_payment((select val::uuid from ck37_ids where key='claim'),true);
do $$ declare v_net bigint; begin
 select b.net_paisa into v_net from public.get_group_balances((select val::uuid from ck37_ids where key='group')) b
  where b.user_id='00000000-0000-4000-8000-000000003702'::uuid;
 if v_net is distinct from 0 then raise exception 'Confirmed early payment failed to clear net; got %',v_net; end if;
end $$;

-- Add LAST month's expense, then call existing manual closure twice.
-- Automatic closure uses the same core function and is checked separately.
select public.record_expense((select val::uuid from ck37_ids where key='group'),10000,
 array['00000000-0000-4000-8000-000000003701'::uuid,'00000000-0000-4000-8000-000000003702'::uuid],
 gen_random_uuid(),'Previous month chai',
 ((date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 second') at time zone 'Asia/Karachi'));
insert into ck37_ids values ('period',public.close_settlement_month(
 (select val::uuid from ck37_ids where key='group'),
 (date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 month')::date)::text);
do $$ declare v_period uuid; begin
 v_period := public.close_settlement_month((select val::uuid from ck37_ids where key='group'),
  (date_trunc('month',now() at time zone 'Asia/Karachi')-interval '1 month')::date);
 if v_period is distinct from (select val::uuid from ck37_ids where key='period') then
   raise exception 'Close not idempotent'; end if;
end $$;
select 'PASS - all local tests; rollback follows' as test_result;
rollback;
