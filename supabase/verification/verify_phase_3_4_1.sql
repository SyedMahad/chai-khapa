-- Safe, READ-ONLY production structural check.
-- RLS permission tests with actual distinct users are still required.
with expected as (
  select unnest(array['leave_group(uuid)','delete_empty_group(uuid)']) as signature
), funcs as (
  select e.signature, p.oid, p.prosecdef, p.proconfig,
         has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_can_execute,
         has_function_privilege('anon',p.oid,'EXECUTE') as anon_can_execute
  from expected e
  left join pg_proc p on p.oid = to_regprocedure('public.' || e.signature)
)
select signature,
       case when oid is not null and not prosecdef and authenticated_can_execute and not anon_can_execute then 'PASS' else 'FAIL' end as public_rpc_status
from funcs order by signature;

with expected as (
  select unnest(array['leave_group(uuid)','delete_empty_group(uuid)']) as signature
), funcs as (
  select e.signature, p.oid,p.prosecdef,p.proconfig
  from expected e
  left join pg_proc p on p.oid = to_regprocedure('app_private.' || e.signature)
)
select signature,
       case when oid is not null and prosecdef
                 and exists (select 1 from unnest(proconfig) c where c in ('search_path=','search_path=""'))
            then 'PASS' else 'FAIL' end as private_definer_status
from funcs order by signature;
