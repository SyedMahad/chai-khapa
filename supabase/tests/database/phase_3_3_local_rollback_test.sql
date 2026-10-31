-- Chai Khapa Phase 3.3 integration test (LOCAL Supabase ONLY).
-- Never run against chai-khapa-prod: creates fake auth.users in a transaction.
-- Requires both earlier migrations plus the Phase 3.3 migration.
-- Execute as a privileged local database role with permission to SET ROLE.
-- Intended for `psql -v ON_ERROR_STOP=1 -f ...` against LOCAL Supabase DB.
-- No changes remain after ROLLBACK. Any failed assertion aborts the test.

begin;

-- Test identities are reserved deterministic UUIDs, not real people.
insert into auth.users(
  id, instance_id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
('00000000-0000-4000-8000-000000000a01', '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','phase33-a@example.invalid', now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-000000000b02', '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','phase33-b@example.invalid', now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-000000000c03', '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','phase33-c@example.invalid', now(),'{}','{}',now(),now()),
('00000000-0000-4000-8000-000000000d04', '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','phase33-outsider@example.invalid', now(),'{}','{}',now(),now());

set local role authenticated;
create temp table phase33_state (key text primary key, value text) on commit drop;

-- Alice owns first group and generates an invite.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000a01',true);
select public.complete_profile('Alice','Tester');
insert into phase33_state select 'group', public.create_group('Office Chai');
insert into phase33_state select 'token', (public.create_group_invite(
    (select value::uuid from phase33_state where key='group'), 3, 24)->>'token');

-- Bob and Charlie join the same group using the token.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000b02',true);
select public.complete_profile('Bob','Tester');
select public.join_group((select value from phase33_state where key='token'));
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000c03',true);
select public.complete_profile('Charlie','Tester');
select public.join_group((select value from phase33_state where key='token'));

-- Alice records Rs. 100.00 split three ways: 3334/3333/3333 paisa.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000a01',true);
insert into phase33_state select 'expense', public.record_expense(
  (select value::uuid from phase33_state where key='group'),
  10000,
  array[
    '00000000-0000-4000-8000-000000000a01'::uuid,
    '00000000-0000-4000-8000-000000000b02'::uuid,
    '00000000-0000-4000-8000-000000000c03'::uuid
  ],
  '00000000-0000-4000-8000-00000000e001'::uuid
)::text;

-- Idempotent retry must return same ID; it cannot double-spend or notify twice.
do $$
declare
  v_id uuid;
  v_group uuid;
begin
  select value::uuid into v_group from phase33_state where key='group';
  select public.record_expense(
    v_group, 10000,
    array['00000000-0000-4000-8000-000000000a01'::uuid,
          '00000000-0000-4000-8000-000000000b02'::uuid,
          '00000000-0000-4000-8000-000000000c03'::uuid],
    '00000000-0000-4000-8000-00000000e001'::uuid
  ) into v_id;
  if v_id <> (select value::uuid from phase33_state where key='expense') then
    raise exception 'FAIL: expense idempotency changed ID';
  end if;
end;
$$;

-- Financial verification + notification persistence; visible as group member.
do $$
declare
  v_group uuid;
  v_expense uuid;
  v_total bigint;
  v_count integer;
  v_notifications integer;
  v_net_total bigint;
begin
  select value::uuid into v_group from phase33_state where key='group';
  select value::uuid into v_expense from phase33_state where key='expense';
  select sum(share_paisa), count(*) into v_total, v_count
    from public.expense_shares where expense_id=v_expense;
  if v_total <> 10000 or v_count <> 3 then
    raise exception 'FAIL: shares total %, attendees %',v_total,v_count;
  end if;
  if (select max(share_paisa)-min(share_paisa) from public.expense_shares
      where expense_id=v_expense) > 1 then
    raise exception 'FAIL: incorrect paisa rounding';
  end if;
  select count(*) into v_notifications from public.notifications
    where target_type='expense' and target_id=v_expense;
  if v_notifications <> 0 then
    -- Alice is payer: recipient notifications are private to Bob and Charlie.
    raise exception 'FAIL: payer sees other people notifications';
  end if;
  select coalesce(sum(net_paisa),0) into v_net_total
    from public.get_group_balances(v_group);
  if v_net_total <> 0 then
    raise exception 'FAIL: group balances do not sum to zero';
  end if;
end;
$$;

-- Bob can see exactly his notification and mark it as read.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000b02',true);
do $$
declare
  v_notice uuid;
  v_count integer;
begin
  select count(*), min(id) into v_count,v_notice
  from public.notifications where type='expense_created';
  if v_count <> 1 then raise exception 'FAIL: Bob inbox count %',v_count; end if;
  if not public.mark_notification_read(v_notice) then
    raise exception 'FAIL: Bob could not acknowledge his notification';
  end if;
  if (select read_at from public.notifications where id=v_notice) is null then
    raise exception 'FAIL: read_at not saved';
  end if;
end;
$$;

-- Outsider cannot read Office Chai nor group balances, and cannot write tables.
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000d04',true);
do $$
declare
  v_group uuid;
begin
  select value::uuid into v_group from phase33_state where key='group';
  if exists (select 1 from public.groups where id=v_group) then
    raise exception 'FAIL: outsider can read group';
  end if;
  if exists (select 1 from public.expenses where group_id=v_group) then
    raise exception 'FAIL: outsider can read expenses';
  end if;
  begin
    perform * from public.get_group_balances(v_group);
    raise exception 'FAIL: outsider obtained balances';
  exception when insufficient_privilege then
    null; -- expected SQLSTATE 42501
  end;
  begin
    perform public.record_expense(v_group,100,
      array['00000000-0000-4000-8000-000000000d04'::uuid],
      gen_random_uuid());
    raise exception 'FAIL: outsider recorded into group';
  exception when insufficient_privilege then
    null; -- expected SQLSTATE 42501
  end;
end;
$$;

-- Local checks passed if no exception occurred above.
select 'PASS: Phase 3.3 local multi-user checks (rolled back below)' as result;
rollback;
