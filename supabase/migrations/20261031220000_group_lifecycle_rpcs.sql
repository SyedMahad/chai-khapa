-- Chai Khapa | Phase 3.4.1 | Group lifecycle operations.
-- Apply AFTER 20261031190000_backend_core_rpcs.sql.
-- These functions are called by authenticated clients only through public RPCs.
-- Historical ledger entries are never deleted by this migration.
begin;

create function app_private.leave_group(p_group_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_net bigint;
begin
  if v_actor is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_group_id is null then
    raise exception 'Group ID is required' using errcode = '22023';
  end if;

  select gm.role into v_role
  from public.group_members gm
  where gm.group_id = p_group_id and gm.user_id = v_actor and gm.left_at is null
  for update;
  if not found then
    raise exception 'You are not an active member of this group' using errcode = '42501';
  end if;
  if v_role = 'owner' then
    raise exception 'The owner cannot leave. Delete an empty group or transfer ownership in a future release'
      using errcode = '22023';
  end if;

  select
    coalesce((select sum(e.amount_paisa) from public.expenses e
              where e.group_id = p_group_id and e.paid_by_user_id = v_actor and e.voided_at is null), 0)
    -
    coalesce((select sum(es.share_paisa) from public.expense_shares es
              join public.expenses e on e.id = es.expense_id
              where e.group_id = p_group_id and es.user_id = v_actor and e.voided_at is null), 0)
  into v_net;

  if v_net <> 0 then
    raise exception 'You have an outstanding net balance. Settle it before leaving this group'
      using errcode = '22023';
  end if;

  -- Keep the membership row to preserve historical foreign keys/expense audit.
  update public.group_members gm
  set left_at = now()
  where gm.group_id = p_group_id and gm.user_id = v_actor and gm.left_at is null;

  return true;
end;
$$;

create function public.leave_group(p_group_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select app_private.leave_group(p_group_id);
$$;

-- Only EMPTY groups can be hard-deleted. Expense history is NEVER erased.
create function app_private.delete_empty_group(p_group_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_owner uuid;
  v_archived_at timestamptz;
begin
  if v_actor is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_group_id is null then
    raise exception 'Group ID is required' using errcode = '22023';
  end if;

  select g.owner_user_id, g.archived_at into v_owner, v_archived_at
  from public.groups g where g.id = p_group_id
  for update;
  if not found or v_owner <> v_actor then
    raise exception 'Only the group owner may delete the group' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.group_members gm
    where gm.group_id = p_group_id and gm.user_id = v_actor and gm.role = 'owner' and gm.left_at is null
  ) then
    raise exception 'You are not an active owner of the group' using errcode = '42501';
  end if;
  if exists (select 1 from public.expenses e where e.group_id = p_group_id) then
    raise exception 'This group has expense history and cannot be deleted. Archive will be added with settlements'
      using errcode = '22023';
  end if;

  -- No expenses means no expense_shares or expense_audit records by foreign keys.
  -- Remove join notifications and unspent invites before membership/group rows.
  delete from public.notifications n where n.group_id = p_group_id;
  delete from public.group_invites gi where gi.group_id = p_group_id;
  delete from public.group_members gm where gm.group_id = p_group_id;
  delete from public.groups g where g.id = p_group_id;
  return true;
end;
$$;

create function public.delete_empty_group(p_group_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select app_private.delete_empty_group(p_group_id);
$$;

-- All paths except these two authenticated RPCs are denied, as in Phase 3.3.
revoke all on function app_private.leave_group(uuid) from public, anon, authenticated;
revoke all on function app_private.delete_empty_group(uuid) from public, anon, authenticated;
grant execute on function app_private.leave_group(uuid) to authenticated;
grant execute on function app_private.delete_empty_group(uuid) to authenticated;
revoke all on function public.leave_group(uuid) from public, anon, authenticated;
revoke all on function public.delete_empty_group(uuid) from public, anon, authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
grant execute on function public.delete_empty_group(uuid) to authenticated;

commit;
