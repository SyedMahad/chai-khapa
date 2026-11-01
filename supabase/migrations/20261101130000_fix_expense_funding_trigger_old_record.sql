-- Chai Khapa | Phase 3.8.3: fix shared funding trigger for two table shapes
-- Apply AFTER 20261101120000_fix_multi_contributor_uuid_aggregate.sql.
-- This replaces one trigger FUNCTION only; it does not change or rewrite ledger rows.
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('app_private.assert_expense_fully_funded()') IS NULL THEN
    RAISE EXCEPTION 'Phase 3.8 funding trigger function is missing; stop and investigate';
  END IF;
  IF to_regclass('public.expense_contributions') IS NULL THEN
    RAISE EXCEPTION 'Phase 3.8 expense_contributions table is missing; stop and investigate';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION app_private.assert_expense_fully_funded()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_expense_id uuid;
  v_contributed numeric;
  v_bill bigint;
BEGIN
  -- expenses has "id", NOT "expense_id".
  -- expense_contributions has "expense_id", NOT "id".
  -- Use separate IF statements so PostgreSQL never tries to resolve an
  -- OLD/NEW field belonging to the OTHER table's row type.
  IF TG_TABLE_SCHEMA = 'public' AND TG_TABLE_NAME = 'expenses' THEN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
      v_expense_id := NEW.id;
    ELSE
      RAISE EXCEPTION 'Unexpected expense trigger operation: %', TG_OP;
    END IF;
  ELSIF TG_TABLE_SCHEMA = 'public' AND TG_TABLE_NAME = 'expense_contributions' THEN
    IF TG_OP = 'DELETE' THEN
      v_expense_id := OLD.expense_id;
    ELSIF TG_OP IN ('INSERT', 'UPDATE') THEN
      v_expense_id := NEW.expense_id;
    ELSE
      RAISE EXCEPTION 'Unexpected contribution trigger operation: %', TG_OP;
    END IF;
  ELSE
    RAISE EXCEPTION 'Unexpected funding trigger table: %.%', TG_TABLE_SCHEMA, TG_TABLE_NAME;
  END IF;

  SELECT e.amount_paisa INTO v_bill
  FROM public.expenses AS e
  WHERE e.id = v_expense_id;

  -- Preserves the original behavior for an expense row that no longer exists.
  IF v_bill IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(SUM(c.amount_paisa), 0)
  INTO v_contributed
  FROM public.expense_contributions AS c
  WHERE c.expense_id = v_expense_id;

  IF v_contributed <> v_bill::numeric THEN
    RAISE EXCEPTION 'Expense % contributions total % must equal bill %',
      v_expense_id, v_contributed, v_bill
      USING ERRCODE = '23514';
  END IF;

  RETURN NULL; -- Return value ignored by AFTER/constraint triggers.
END
$$;

-- Preserves the principle that clients cannot invoke the privileged trigger function.
REVOKE ALL ON FUNCTION app_private.assert_expense_fully_funded()
FROM PUBLIC, anon, authenticated;

COMMIT;
