-- Read-only production structural verification. Run in Supabase SQL Editor.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='settlement_transfers'
      and column_name in ('source','origin_month','early_batch_id')) as added_transfer_columns_expected_3,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='settlement_periods'
      and column_name='closed_method') as close_method_column_expected_1,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('claim_early_settlements','get_open_month_suggestions'))
    as public_early_rpcs_expected_2,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app_private' and p.proname in
      ('claim_early_settlements','open_month_suggestions','close_settlement_month_core','run_auto_month_closures'))
    as private_rpcs_expected_4,
  (select count(*) from pg_tables where schemaname='public'
    and tablename in ('settlement_transfers','settlement_periods','settlement_payment_claims','settlement_job_log')
    and rowsecurity) as settlement_rls_tables_expected_4,
  has_function_privilege('anon','public.claim_early_settlements(uuid,uuid[],bigint[],uuid,boolean)','EXECUTE')
    as anon_can_claim_should_be_false,
  has_function_privilege('authenticated','app_private.run_auto_month_closures()','EXECUTE')
    as client_can_auto_close_should_be_false,
  (select count(*) from pg_constraint where conname='notifications_target_check'
    and pg_get_constraintdef(oid) like '%settlement_transfer%') as notification_fix_expected_1;

-- Verify scheduled job separately AFTER enabling Supabase Cron (optional).
-- select jobname,schedule,active from cron.job where jobname='chai-khapa-month-close';
-- select outcome,period_month,ran_at,error_text from public.settlement_job_log order by id desc limit 20;
