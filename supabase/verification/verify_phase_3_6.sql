-- Read-only production structural verification for Phase 3.6.
select
 (select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname in ('settlement_periods','settlement_transfers','settlement_payment_claims') and c.relrowsecurity) as rls_tables_expected_3,
 (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('close_settlement_month','mark_transfer_paid','confirm_transfer_payment')) as public_rpcs_expected_3,
 (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname in ('close_settlement_month','mark_transfer_paid','confirm_transfer_payment')) as private_rpcs_expected_3,
 (select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname in ('settlement_periods','settlement_transfers','settlement_payment_claims')
  and pg_catalog.has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE')) as writable_client_tables_expected_0,
 (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in ('close_settlement_month','mark_transfer_paid','confirm_transfer_payment')
  and pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE')) as anon_rpc_expected_0;

-- Expected: all three new tables have SELECT-only RLS policies.
select tablename, policyname, cmd, roles from pg_catalog.pg_policies
where schemaname='public' and tablename in ('settlement_periods','settlement_transfers','settlement_payment_claims')
order by tablename;

-- Expected 3 private funcs have security definer, pinned search path and 3 wrappers are invoker.
select n.nspname,p.proname,p.prosecdef,p.proconfig
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','app_private')
 and p.proname in ('close_settlement_month','mark_transfer_paid','confirm_transfer_payment')
order by n.nspname,p.proname;
