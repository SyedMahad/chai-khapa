-- Chai Khapa 3.7.1 — read-only discovery of missed settlement months.
-- The existing public.close_settlement_month RPC performs actual closure,
-- with owner-only checks and transaction-safe idempotency.
-- The browser NEVER calls app_private.run_auto_month_closures().
begin;

create function app_private.list_pending_settlement_months()
returns table (
  group_id uuid,
  group_name text,
  period_month date,
  session_count bigint,
  total_paisa bigint,
  can_close boolean
)
language sql stable security definer set search_path = '' as $function$
  with visible_groups as (
    select g.id, g.name, g.timezone, g.owner_user_id
    from public.groups g
    join public.group_members gm on gm.group_id = g.id
    where gm.user_id = (select auth.uid()) and gm.left_at is null
  ), months_with_expenses as (
    select
      vg.id as group_id,
      vg.name::text as group_name,
      date_trunc('month', e.occurred_at at time zone vg.timezone)::date as period_month,
      count(*)::bigint as session_count,
      sum(e.amount_paisa)::bigint as total_paisa,
      vg.owner_user_id
    from visible_groups vg
    join public.expenses e on e.group_id = vg.id and e.voided_at is null
    where date_trunc('month', e.occurred_at at time zone vg.timezone)::date
          < date_trunc('month', now() at time zone vg.timezone)::date
    group by vg.id, vg.name, vg.timezone, vg.owner_user_id,
             date_trunc('month', e.occurred_at at time zone vg.timezone)::date
  )
  select m.group_id, m.group_name, m.period_month, m.session_count,
         m.total_paisa, (m.owner_user_id = (select auth.uid())) as can_close
  from months_with_expenses m
  where not exists (
    select 1 from public.settlement_periods sp
    where sp.group_id = m.group_id and sp.period_month = m.period_month
  )
  order by m.period_month asc, m.group_name asc
$function$;

revoke all on function app_private.list_pending_settlement_months() from public, anon, authenticated;
grant execute on function app_private.list_pending_settlement_months() to authenticated;

create function public.list_pending_settlement_months()
returns table (
  group_id uuid,
  group_name text,
  period_month date,
  session_count bigint,
  total_paisa bigint,
  can_close boolean
)
language sql stable security invoker set search_path = '' as $function$
  select * from app_private.list_pending_settlement_months()
$function$;

revoke all on function public.list_pending_settlement_months() from public, anon, authenticated;
grant execute on function public.list_pending_settlement_months() to authenticated;

commit;
