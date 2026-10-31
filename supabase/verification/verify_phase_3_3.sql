-- Phase 3.3 read-only production verification (safe for Supabase SQL Editor).
-- Expected: 8 exposed RPC wrappers, 8 private implementations,
-- 8 wrappers SECURITY INVOKER, 8 implementations SECURITY DEFINER,
-- 0 anon-callable wrappers, 0 direct authenticated writes, RLS still 8.

with required_functions(signature) as (
  values
    ('complete_profile(text,text)'),
    ('create_group(text)'),
    ('create_group_invite(uuid,integer,integer)'),
    ('join_group(text)'),
    ('record_expense(uuid,bigint,uuid[],uuid,text,timestamptz)'),
    ('get_group_balances(uuid)'),
    ('mark_notification_read(uuid)'),
    ('mark_all_notifications_read()')
),
wrappers as (
  select f.signature, to_regprocedure('public.' || f.signature) as fn_oid
  from required_functions f
), implementations as (
  select f.signature, to_regprocedure('app_private.' || f.signature) as fn_oid
  from required_functions f
), expected_tables(name) as (
  values ('profiles'), ('groups'), ('group_members'), ('group_invites'),
         ('expenses'), ('expense_shares'), ('expense_audit'), ('notifications')
)
select
  (select count(*) from wrappers where fn_oid is not null) as public_rpcs,
  (select count(*) from implementations where fn_oid is not null) as private_implementations,
  (select count(*) from wrappers w join pg_proc p on p.oid=w.fn_oid
     where not p.prosecdef) as safe_invoker_wrappers,
  (select count(*) from implementations f join pg_proc p on p.oid=f.fn_oid
     where p.prosecdef and exists (
       select 1 from unnest(p.proconfig) cfg where cfg='search_path='))
    as pinned_private_definers,
  (select count(*) from wrappers w
     where w.fn_oid is not null
       and has_function_privilege('anon', w.fn_oid, 'EXECUTE'))
    as anon_callable_rpcs,
  (select count(*) from wrappers w
     where w.fn_oid is not null
       and not has_function_privilege('authenticated', w.fn_oid, 'EXECUTE'))
    as missing_authenticated_rpc_grants,
  (select count(*) from expected_tables t join pg_class c on c.relname=t.name
     join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
     where c.relrowsecurity) as rls_enabled_tables,
  (select count(*) from expected_tables t join pg_class c on c.relname=t.name
     join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
     where has_table_privilege('authenticated', c.oid, 'INSERT,UPDATE,DELETE'))
    as writable_client_tables;

-- Important: Structural checks do NOT replace authenticated integration tests.
-- Run the rollback-only local test in supabase/tests/database on a LOCAL DB.
