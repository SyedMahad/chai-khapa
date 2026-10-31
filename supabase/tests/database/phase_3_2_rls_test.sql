-- Chai Khapa Phase 3.2 RLS integration test
-- FOR LOCAL SUPABASE DATABASE ONLY (supabase test db), NOT PRODUCTION.
-- Creates three fake Auth accounts and two groups inside a ROLLBACK transaction.
-- Exercises real Postgres RLS by SET LOCAL ROLE + simulated auth.uid() claims.

begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

create temp table ck_fixture (
  label text primary key,
  id uuid not null default gen_random_uuid()
) on commit drop;
insert into ck_fixture(label) values
  ('alice'), ('bob'), ('carol'), ('group_a'), ('group_b'), ('expense_a'), ('expense_b');

insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
select id, '00000000-0000-0000-0000-000000000000'::uuid,
       'authenticated', 'authenticated',
       'rls-' || id::text || '@example.invalid', now(), now()
from ck_fixture where label in ('alice', 'bob', 'carol');
-- Phase 3.1's auth.users trigger creates their public.profiles rows.

update public.profiles p
set first_name = case when f.label = 'alice' then 'Alice'
                      when f.label = 'bob' then 'Bob' else 'Carol' end,
    last_name = 'Test'
from ck_fixture f
where p.user_id = f.id and f.label in ('alice', 'bob', 'carol');

insert into public.groups (id, name, owner_user_id)
values
  ((select id from ck_fixture where label='group_a'), 'Chai Group A',
    (select id from ck_fixture where label='alice')),
  ((select id from ck_fixture where label='group_b'), 'Chai Group B',
    (select id from ck_fixture where label='carol'));

insert into public.group_members(group_id, user_id, role)
values
  ((select id from ck_fixture where label='group_a'), (select id from ck_fixture where label='alice'), 'owner'),
  ((select id from ck_fixture where label='group_a'), (select id from ck_fixture where label='bob'), 'member'),
  ((select id from ck_fixture where label='group_b'), (select id from ck_fixture where label='carol'), 'owner');

insert into public.expenses
 (id, group_id, created_by_user_id, paid_by_user_id, amount_paisa, request_id)
values
  ((select id from ck_fixture where label='expense_a'),
   (select id from ck_fixture where label='group_a'),
   (select id from ck_fixture where label='alice'),
   (select id from ck_fixture where label='alice'), 14000, gen_random_uuid()),
  ((select id from ck_fixture where label='expense_b'),
   (select id from ck_fixture where label='group_b'),
   (select id from ck_fixture where label='carol'),
   (select id from ck_fixture where label='carol'), 7000, gen_random_uuid());

insert into public.expense_shares(expense_id, group_id, user_id, share_paisa)
values
  ((select id from ck_fixture where label='expense_a'),
   (select id from ck_fixture where label='group_a'),
   (select id from ck_fixture where label='alice'), 7000),
  ((select id from ck_fixture where label='expense_a'),
   (select id from ck_fixture where label='group_a'),
   (select id from ck_fixture where label='bob'), 7000),
  ((select id from ck_fixture where label='expense_b'),
   (select id from ck_fixture where label='group_b'),
   (select id from ck_fixture where label='carol'), 7000);

insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body)
values
  ((select id from ck_fixture where label='alice'),
   (select id from ck_fixture where label='group_a'), 'test-alice','expense.created','Chai','test'),
  ((select id from ck_fixture where label='bob'),
   (select id from ck_fixture where label='group_a'), 'test-bob','expense.created','Chai','test'),
  ((select id from ck_fixture where label='carol'),
   (select id from ck_fixture where label='group_b'), 'test-carol','expense.created','Chai','test');

-- Alice's session may see Group A records but not Group B.
select set_config('request.jwt.claim.sub', (select id::text from ck_fixture where label='alice'), true);
set local role authenticated;
select extensions.is((select count(*) from public.groups), 1::bigint, 'Alice sees exactly her group');
select extensions.is((select count(*) from public.group_members), 2::bigint, 'Alice sees only Group A memberships');
select extensions.is((select count(*) from public.expenses), 1::bigint, 'Alice sees only Group A expenses');
select extensions.is((select count(*) from public.expense_shares), 2::bigint, 'Alice sees only Group A shares');
select extensions.is((select count(*) from public.profiles), 2::bigint, 'Alice sees herself and Bob, not Carol');
select extensions.is((select count(*) from public.notifications), 1::bigint, 'Alice sees only her own notification');
select extensions.ok(not has_table_privilege('authenticated','public.expenses','INSERT'), 'Client cannot insert expense directly');
select extensions.ok(not has_table_privilege('authenticated','public.notifications','UPDATE'), 'Client cannot mutate notifications directly');
reset role;

-- Bob is a member, not owner. He can READ the group's expenses.
select set_config('request.jwt.claim.sub', (select id::text from ck_fixture where label='bob'), true);
set local role authenticated;
select extensions.is((select count(*) from public.groups), 1::bigint, 'Bob as member sees his group');
select extensions.is((select count(*) from public.profiles), 2::bigint, 'Bob sees his fellow member profile');
select extensions.is((select count(*) from public.expenses), 1::bigint, 'Bob reads group expense');
select extensions.is((select count(*) from public.notifications), 1::bigint, 'Bob does not see Alice or Carol notification');
reset role;

-- Carol is a completely unrelated group owner and cannot read Group A.
select set_config('request.jwt.claim.sub', (select id::text from ck_fixture where label='carol'), true);
set local role authenticated;
select extensions.is((select count(*) from public.groups), 1::bigint, 'Carol only sees Group B');
select extensions.is((select count(*) from public.expenses), 1::bigint, 'Carol only sees her own expense');
select extensions.is((select count(*) from public.expense_shares), 1::bigint, 'Carol cannot read Group A shares');
select extensions.is((select count(*) from public.profiles), 1::bigint, 'Carol cannot read Alice or Bob profiles');
select extensions.is((select count(*) from public.notifications), 1::bigint, 'Carol only sees her own notification');
reset role;

-- Anonymous clients cannot select even before reaching RLS policy checks.
select extensions.ok(not has_table_privilege('anon', 'public.groups','SELECT'), 'Anonymous user lacks group SELECT grant');

-- Once Bob leaves, his group read access stops, while his own inbox survives.
update public.group_members
set left_at = clock_timestamp()
where group_id = (select id from ck_fixture where label='group_a')
  and user_id = (select id from ck_fixture where label='bob');
select set_config('request.jwt.claim.sub', (select id::text from ck_fixture where label='bob'), true);
set local role authenticated;
select extensions.is((select count(*) from public.expenses), 0::bigint, 'Former member cannot read old group expense');
select extensions.is((select count(*) from public.notifications), 1::bigint, 'Former member retains their personal inbox');
reset role;

select * from extensions.finish();
rollback;
