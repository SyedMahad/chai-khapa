-- Chai Khapa Phase 3.2: READ-ONLY, safe to run in Supabase Production SQL Editor.
-- These checks verify objects and privileges, NOT full isolation behavior.
-- Expect PASS for every row. Follow with test file locally for real RLS proofs.

-- 1) Eight RLS-enabled tables.
select c.relname as table_name,
       case when c.relrowsecurity then 'PASS' else 'FAIL' end as rls_enabled
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and c.relname in (
    'profiles', 'groups', 'group_members', 'group_invites',
    'expenses', 'expense_shares', 'expense_audit', 'notifications'
  )
order by 1;

-- 2) Role privilege matrix. Expect exactly 8 rows, all PASS.
with expected(table_name, client_can_read) as (
  values
    ('profiles', true), ('groups', true), ('group_members', true),
    ('group_invites', false), ('expenses', true), ('expense_shares', true),
    ('expense_audit', false), ('notifications', true)
)
select table_name,
       case when
         has_table_privilege('authenticated', format('public.%I', table_name), 'SELECT') = client_can_read
         and not has_table_privilege('anon', format('public.%I', table_name), 'SELECT')
         and not has_table_privilege('anon', format('public.%I', table_name), 'INSERT, UPDATE, DELETE, TRUNCATE')
         and not has_table_privilege('authenticated', format('public.%I', table_name), 'INSERT, UPDATE, DELETE, TRUNCATE')
       then 'PASS' else 'FAIL' end as privilege_status
from expected
order by 1;

-- 3) Policy presence. Expected 6 SELECT policies, none for sensitive tables.
select tablename, policyname, cmd, roles, qual
from pg_catalog.pg_policies
where schemaname = 'public'
  and tablename in (
    'profiles', 'groups', 'group_members', 'group_invites',
    'expenses', 'expense_shares', 'expense_audit', 'notifications'
  )
order by tablename, policyname;

-- 4) Private helper privileges. Authenticated = true, anon = false.
select p.proname as helper,
       has_schema_privilege('authenticated', 'app_private', 'USAGE') as authenticated_schema_usage,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
       p.prosecdef as security_definer,
       (exists (select 1 from unnest(p.proconfig) as setting where setting like 'search_path=%')) as pinned_search_path
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'app_private'
  and p.proname in ('my_active_group_ids','visible_profile_user_ids')
order by p.proname;

-- 5) Auth/profile trigger from Phase 3.1 should still exist.
select case when exists (
  select 1
  from pg_catalog.pg_trigger t
  join pg_catalog.pg_class c on c.oid = t.tgrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'auth' and c.relname = 'users'
    and t.tgname = 'chai_khapa_auth_user_created' and not t.tgisinternal
) then 'PASS' else 'FAIL' end as profile_bootstrap_trigger;
