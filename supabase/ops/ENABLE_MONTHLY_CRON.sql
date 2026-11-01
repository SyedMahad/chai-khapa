-- OPERATIONS — run deliberately in Supabase SQL Editor AS postgres, AFTER
-- applying 20261101030000_early_settlements_and_auto_close.sql and testing.
-- Back up first. A catch-up run may lock completed months and create obligations.
-- Daily at 19:05 UTC = 00:05 PKT next day (Pakistan stays UTC+05:00).
-- For groups in other time zones, their completed months are picked up by
-- the next daily job after local month-end. Keep DB timezone in UTC.

create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'chai-khapa-month-close',
  '5 19 * * *',
  $$ select app_private.run_auto_month_closures() $$
);

-- Optional ONE-TIME catch-up for any completed months already missed.
-- Run only after inspecting your data; this has REAL financial side effects.
-- select app_private.run_auto_month_closures() as months_closed_now;

-- Check job details; latest attempts in Integrations -> Cron -> History.
select jobid,jobname,schedule,command,active
from cron.job where jobname='chai-khapa-month-close';
