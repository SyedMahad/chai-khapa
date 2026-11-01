-- READ-ONLY production checks; safe to run in the Supabase SQL Editor.
select
  to_regprocedure('public.claim_month_payments(uuid[],bigint[],uuid,boolean)') is not null as batch_rpc_exists,
  to_regprocedure('public.my_month_session_details(uuid,date)') is not null as session_details_rpc_exists,
  to_regprocedure('app_private.claim_month_payments(uuid[],bigint[],uuid,boolean)') is not null as private_batch_exists,
  not has_function_privilege('anon','public.claim_month_payments(uuid[],bigint[],uuid,boolean)','EXECUTE') as anonymous_blocked,
  has_function_privilege('authenticated','public.claim_month_payments(uuid[],bigint[],uuid,boolean)','EXECUTE') as authenticated_allowed,
  not has_table_privilege('authenticated','public.settlement_payment_claims','INSERT,UPDATE,DELETE') as direct_claim_writes_blocked;

select
  count(*) filter (where status='confirmed' and applied_paisa <> amount_paisa) as malformed_confirmed,
  count(*) filter (where applied_paisa < 0 or applied_paisa > amount_paisa) as invalid_applied,
  count(*) filter (where status='awaiting_confirmation' and not exists(
    select 1 from public.settlement_payment_claims c where c.transfer_id=t.id and c.status='pending'
  )) as awaiting_without_claim
from public.settlement_transfers t;

select
  count(*) filter (where applied_paisa <= 0) as invalid_claim_amounts,
  count(*) filter (where actual_paid_paisa <> applied_paisa+rounding_adjustment_paisa) as mismatched_rounding,
  count(*) filter (where status='pending' and decided_at is not null) as invalid_pending_decisions
from public.settlement_payment_claims;

select p.proname, p.prosecdef,
  exists(select 1 from unnest(p.proconfig) cfg where cfg in ('search_path=', 'search_path=""')) as pinned_search_path
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='app_private' and p.proname in (
 'claim_month_payments','confirm_transfer_payment','claim_early_settlements','get_group_balances','my_month_session_details'
);
