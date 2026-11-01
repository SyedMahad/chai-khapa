-- Chai Khapa Phase 3.8.1 — READ ONLY diagnostic checks.
-- Safe to run in production SQL Editor. No ledger records are modified.

-- 1: New contribution table present?
select to_regclass('public.expense_contributions') is not null as contributions_table_exists;

-- 2: Exact exposed function signature and authenticated EXECUTE permission.
select n.nspname as function_schema, p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as parameter_signature,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='record_expense_multi';

-- 3: Number of stored contribution records versus expense records.
select (select count(*) from public.expenses) as expenses_count,
       (select count(*) from public.expense_contributions) as contribution_rows,
       (select count(*) from public.expenses e
        left join (select expense_id, sum(amount_paisa) as covered
                   from public.expense_contributions group by expense_id) c on c.expense_id=e.id
        where c.covered is distinct from e.amount_paisa) as amounts_not_fully_covered;

-- If RPC returns PGRST202 but function exists with matching arguments,
-- schema cache may be stale. Do not modify function definitions blindly.
-- PostgREST documented reload command (NOT part of this read-only query):
-- NOTIFY pgrst, 'reload schema';
