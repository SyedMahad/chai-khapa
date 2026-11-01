-- Read-only structural checks. Run in Supabase SQL Editor after applying migration.
select
  to_regprocedure('public.list_pending_settlement_months()') is not null as public_rpc_exists,
  to_regprocedure('app_private.list_pending_settlement_months()') is not null as private_helper_exists,
  has_function_privilege('authenticated','public.list_pending_settlement_months()','EXECUTE') as authenticated_can_call,
  not has_function_privilege('anon','public.list_pending_settlement_months()','EXECUTE') as anonymous_cannot_call,
  to_regprocedure('public.close_settlement_month(uuid,date)') is not null as existing_close_rpc_exists;
-- To check pending months as a real member, open Chai Khapa → Settlements.
-- Running the RPC as a SQL editor superuser does NOT simulate a logged-in member.
