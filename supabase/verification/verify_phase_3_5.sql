-- Chai Khapa 3.5: production-safe read-only verification; does not test authorization behavior.
with expected(name, arguments) as (
  values
  ('rename_group', 'uuid, text'),
  ('set_group_archived', 'uuid, boolean'),
  ('transfer_group_ownership', 'uuid, uuid')
), functions as (
 select e.name,
   to_regprocedure('public.'||e.name||'('||e.arguments||')') as public_rpc,
   to_regprocedure('app_private.'||e.name||'('||e.arguments||')') as private_impl
 from expected e
)
select name, case when public_rpc is not null and private_impl is not null then 'PASS' else 'FAIL' end as exists_status,
  case when public_rpc is not null and has_function_privilege('authenticated',public_rpc,'EXECUTE') and not has_function_privilege('anon',public_rpc,'EXECUTE') then 'PASS' else 'FAIL' end as rpc_grants
from functions order by name;

-- The group totals RPC must not reject archived groups; confirm source definition has no archived_at restriction
-- in its membership permission check. Inspect definition directly in SQL editor if needed:
select pg_get_functiondef('app_private.get_group_balances(uuid)'::regprocedure) as balances_function_definition;
