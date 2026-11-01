-- READ ONLY. Run in Supabase SQL Editor after applying Phase 3.8.2.
-- Expected: function_installed=true, fixed_uuid_selection=true,
--           security_definer=true, fixed_search_path=true, authenticated_can_execute=true.
WITH fn AS (
  SELECT p.oid, p.prosecdef, p.proconfig,
         pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='app_private'
    AND p.oid=to_regprocedure('app_private.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)')
)
SELECT EXISTS(SELECT 1 FROM fn) AS function_installed,
       EXISTS(SELECT 1 FROM fn WHERE position('order by c.user_id limit 1' in lower(definition)) > 0
                 AND position('min(c.user_id)' in lower(definition))=0) AS fixed_uuid_selection,
       EXISTS(SELECT 1 FROM fn WHERE prosecdef) AS security_definer,
       EXISTS(SELECT 1 FROM fn WHERE 'search_path=""'=ANY(proconfig) OR 'search_path='=ANY(proconfig)) AS fixed_search_path,
       EXISTS(SELECT 1 FROM fn WHERE has_function_privilege('authenticated', oid, 'EXECUTE')) AS authenticated_can_execute;

-- Diagnostic if 42883 persists: paste the *message* and *hint* from the
-- browser console, not tokens or authorization headers. The frontend now
-- distinguishes PostgreSQL 42883 from PostgREST PGRST202.
