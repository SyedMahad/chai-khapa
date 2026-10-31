-- Chai Khapa | Phase 3.1 | Read-only verification after applying migration.
-- Run in Supabase SQL Editor. Returns status rows; all should show PASS.
with expected(name) as (
  values ('profiles'), ('groups'), ('group_members'), ('group_invites'),
         ('expenses'), ('expense_shares'), ('expense_audit'), ('notifications')
), checks as (
  select
    e.name,
    c.oid is not null as table_exists,
    coalesce(c.relrowsecurity, false) as rls_enabled,
    case when c.oid is null then false else not has_table_privilege('anon', c.oid, 'SELECT') end as anon_select_blocked,
    case when c.oid is null then false else not has_table_privilege('authenticated', c.oid, 'SELECT') end as authenticated_select_blocked,
    case when c.oid is null then false else not has_table_privilege('authenticated', c.oid, 'INSERT') end as authenticated_insert_blocked
  from expected e
  left join pg_catalog.pg_class c
    on c.relname = e.name
   and c.relnamespace = 'public'::regnamespace
   and c.relkind = 'r'
)
select
  name,
  case when table_exists and rls_enabled and anon_select_blocked
    and authenticated_select_blocked and authenticated_insert_blocked
    then 'PASS' else 'FAIL' end as result,
  table_exists, rls_enabled, anon_select_blocked,
  authenticated_select_blocked, authenticated_insert_blocked
from checks
order by name;

-- Confirm the sign-in bootstrap trigger exists.
select
  case when exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where t.tgname = 'chai_khapa_auth_user_created'
      and n.nspname = 'auth' and c.relname = 'users'
      and not t.tgisinternal
  ) then 'PASS' else 'FAIL' end as auth_profile_trigger;

-- Confirm the base ledger fields use bigint (paisa, not float).
select
  table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'expenses' and column_name = 'amount_paisa')
    or (table_name = 'expense_shares' and column_name = 'share_paisa')
  )
order by table_name, column_name;
