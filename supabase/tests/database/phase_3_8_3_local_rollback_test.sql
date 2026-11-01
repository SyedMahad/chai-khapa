-- LOCAL DATABASE ONLY. Do not run on production.
-- Exercises both expense and contribution UPDATE triggers without retaining changes.
-- Requires at least one existing expense with fully funded contributions.
BEGIN;
SET LOCAL statement_timeout = '15s';
DO $$
DECLARE
  v_id uuid;
  v_count integer;
BEGIN
  SELECT e.id INTO v_id
  FROM public.expenses e
  WHERE EXISTS (
    SELECT 1 FROM public.expense_contributions c WHERE c.expense_id = e.id
  )
  ORDER BY e.occurred_at DESC LIMIT 1;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Seed one expense in your LOCAL test database before running this test';
  END IF;
  UPDATE public.expenses SET amount_paisa = amount_paisa WHERE id = v_id;
  UPDATE public.expense_contributions SET amount_paisa = amount_paisa WHERE expense_id = v_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count < 1 THEN RAISE EXCEPTION 'Missing contribution rows'; END IF;
END
$$;
-- Forces deferred checks to execute; should succeed without OLD field errors.
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
