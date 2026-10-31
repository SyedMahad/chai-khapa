-- Chai Khapa 3.5: secure owner-only group settings, archived history and transfer.
-- Apply after Phase 3.4.1 group lifecycle migration. No financial ledger rows are edited.
begin;

create function app_private.rename_group(p_group_id uuid, p_name text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_name text := btrim(p_name);
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if v_name is null or length(v_name) not between 2 and 80 then raise exception 'Group name must be 2–80 characters' using errcode='22023'; end if;
 update public.groups g set name = v_name
 where g.id = p_group_id and g.owner_user_id = v_actor and g.archived_at is null
 and exists (select 1 from public.group_members m where m.group_id = g.id and m.user_id = v_actor and m.role='owner' and m.left_at is null);
 if not found then raise exception 'Only an active group owner can rename the group' using errcode='42501'; end if;
 return true;
end $$;

create function public.rename_group(p_group_id uuid, p_name text)
returns boolean language sql security invoker set search_path = '' as $$ select app_private.rename_group(p_group_id,p_name); $$;

create function app_private.set_group_archived(p_group_id uuid,p_archived boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid();
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_archived is null then raise exception 'Archived flag required' using errcode='22023'; end if;
 update public.groups g set archived_at = case when p_archived then greatest(now(),g.created_at) else null end
 where g.id = p_group_id and g.owner_user_id = v_actor
 and exists(select 1 from public.group_members m where m.group_id=g.id and m.user_id=v_actor and m.role='owner' and m.left_at is null);
 if not found then raise exception 'Only an active group owner can archive or reopen the group' using errcode='42501'; end if;
 return true;
end $$;

create function public.set_group_archived(p_group_id uuid,p_archived boolean)
returns boolean language sql security invoker set search_path = '' as $$ select app_private.set_group_archived(p_group_id,p_archived); $$;

create function app_private.transfer_group_ownership(p_group_id uuid,p_new_owner_user_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid();
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_new_owner_user_id is null or p_new_owner_user_id = v_actor then raise exception 'Choose a different active member' using errcode='22023'; end if;
 -- Lock the parent row to serialize concurrent owner changes.
 perform 1 from public.groups g where g.id=p_group_id and g.owner_user_id=v_actor and g.archived_at is null for update;
 if not found then raise exception 'Only the current owner may transfer this group' using errcode='42501'; end if;
 if not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=v_actor and m.role='owner' and m.left_at is null) then
   raise exception 'Owner membership missing' using errcode='42501'; end if;
 if not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=p_new_owner_user_id and m.role='member' and m.left_at is null) then
   raise exception 'New owner must be an active member' using errcode='22023'; end if;
 -- The unique partial index requires demoting the original owner first.
 update public.group_members set role='member' where group_id=p_group_id and user_id=v_actor and role='owner' and left_at is null;
 update public.group_members set role='owner' where group_id=p_group_id and user_id=p_new_owner_user_id and left_at is null;
 update public.groups set owner_user_id=p_new_owner_user_id where id=p_group_id;
 return true;
end $$;

create function public.transfer_group_ownership(p_group_id uuid,p_new_owner_user_id uuid)
returns boolean language sql security invoker set search_path = '' as $$ select app_private.transfer_group_ownership(p_group_id,p_new_owner_user_id); $$;

-- Archived groups must remain readable: allow group balances for active membership even when archived.
create or replace function app_private.get_group_balances(p_group_id uuid)
returns table (
  user_id uuid,
  first_name text,
  last_name text,
  total_paid_paisa bigint,
  total_share_paisa bigint,
  net_paisa bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.group_members gm join public.groups g on g.id = gm.group_id
    where gm.group_id = p_group_id and gm.user_id = auth.uid()
      and gm.left_at is null
  ) then
    raise exception 'Not an active member of this group' using errcode = '42501';
  end if;

  return query
  with paid as (
    select e.paid_by_user_id as uid, sum(e.amount_paisa)::bigint as amount
    from public.expenses e
    where e.group_id = p_group_id and e.voided_at is null
    group by e.paid_by_user_id
  ), consumed as (
    select s.user_id as uid, sum(s.share_paisa)::bigint as amount
    from public.expense_shares s
    join public.expenses e on e.id = s.expense_id
    where e.group_id = p_group_id and e.voided_at is null
    group by s.user_id
  )
  select gm.user_id, p.first_name, p.last_name,
         coalesce(pd.amount, 0)::bigint,
         coalesce(c.amount, 0)::bigint,
         (coalesce(pd.amount, 0) - coalesce(c.amount, 0))::bigint
  from public.group_members gm
  join public.profiles p on p.user_id = gm.user_id
  left join paid pd on pd.uid = gm.user_id
  left join consumed c on c.uid = gm.user_id
  where gm.group_id = p_group_id
  order by p.first_name nulls last, p.last_name nulls last, gm.user_id;
end;
$$;


revoke all on function app_private.rename_group(uuid,text) from public, anon, authenticated;
revoke all on function app_private.set_group_archived(uuid,boolean) from public, anon, authenticated;
revoke all on function app_private.transfer_group_ownership(uuid,uuid) from public, anon, authenticated;
grant execute on function app_private.rename_group(uuid,text) to authenticated;
grant execute on function app_private.set_group_archived(uuid,boolean) to authenticated;
grant execute on function app_private.transfer_group_ownership(uuid,uuid) to authenticated;
revoke all on function public.rename_group(uuid,text) from public, anon, authenticated;
revoke all on function public.set_group_archived(uuid,boolean) from public, anon, authenticated;
revoke all on function public.transfer_group_ownership(uuid,uuid) from public, anon, authenticated;
grant execute on function public.rename_group(uuid,text) to authenticated;
grant execute on function public.set_group_archived(uuid,boolean) to authenticated;
grant execute on function public.transfer_group_ownership(uuid,uuid) to authenticated;
commit;
