-- READ ONLY. Run after applying the migration.
-- Expected: function_exists=t, safe_search_path=t, security_definer=t,
-- guarded_field_access=t, correct_triggers=2, contribution_mismatches=0.
WITH fn AS (
  SELECT p.oid, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) AS definition
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure('app_private.assert_expense_fully_funded()')
), trigger_links AS (
  SELECT COUNT(*)::integer AS matching_triggers
  FROM pg_catalog.pg_trigger t
  JOIN fn ON fn.oid = t.tgfoid
  WHERE (t.tgname = 'expense_funding_after_expense'
         AND t.tgrelid = 'public.expenses'::regclass)
     OR (t.tgname = 'expense_funding_after_contribution'
         AND t.tgrelid = 'public.expense_contributions'::regclass)
), mismatches AS (
  SELECT COUNT(*)::integer AS mismatched_expenses
  FROM public.expenses e
  LEFT JOIN (
    SELECT expense_id, SUM(amount_paisa) AS total
    FROM public.expense_contributions
    GROUP BY expense_id
  ) c ON c.expense_id = e.id
  WHERE COALESCE(c.total, 0) <> e.amount_paisa::numeric
)
SELECT
  EXISTS(SELECT 1 FROM fn) AS function_exists,
  EXISTS(SELECT 1 FROM fn WHERE prosecdef) AS security_definer,
  EXISTS(SELECT 1 FROM fn WHERE
    'search_path=' = ANY(proconfig) OR 'search_path=""' = ANY(proconfig)
  ) AS safe_search_path,
  EXISTS(SELECT 1 FROM fn WHERE
    position('tg_table_name = ''expenses''' IN lower(definition)) > 0
    AND position('tg_table_name = ''expense_contributions''' IN lower(definition)) > 0
    AND position('v_expense_id := new.id' IN lower(definition)) > 0
    AND position('v_expense_id := old.expense_id' IN lower(definition)) > 0
  ) AS guarded_field_access,
  (SELECT matching_triggers FROM trigger_links) AS correct_triggers,
  (SELECT mismatched_expenses FROM mismatches) AS contribution_mismatches,
  EXISTS(SELECT 1 FROM fn WHERE
    NOT has_function_privilege('authenticated', oid, 'EXECUTE')
  ) AS not_callable_by_authenticated_users;
