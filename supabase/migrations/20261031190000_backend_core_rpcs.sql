-- Chai Khapa | Phase 3.3 | Core authenticated operations
-- Requires Phases 3.1 and 3.2, as deployed in chai-khapa-prod.
-- All values ending in _paisa are BIGINT amounts in PKR paisa.
-- Production safety: run as migration owner (postgres), NOT as authenticated.
-- Direct client table INSERT/UPDATE/DELETE remain forbidden.
-- Public RPCs are SECURITY INVOKER wrappers for private SECURITY DEFINER logic.

begin;

-- Abort instead of installing functions against an incompatible earlier schema.
do $$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.groups') is null
     or to_regclass('public.group_members') is null
     or to_regclass('public.group_invites') is null
     or to_regclass('public.expenses') is null
     or to_regclass('public.expense_shares') is null
     or to_regclass('public.expense_audit') is null
     or to_regclass('public.notifications') is null
     or to_regprocedure('app_private.my_active_group_ids()') is null
  then
    raise exception 'Missing Chai Khapa Phase 3.1 / 3.2 objects; do not apply Phase 3.3';
  end if;
end;
$$;

-- Private helpers are not exposed through PostgREST (API exposed schemas must
-- contain public only; NEVER add app_private to the exposed schemas setting).
-- Existing Phase 3.2 helpers already use this schema.
revoke all on schema app_private from public, anon;
grant usage on schema app_private to authenticated;
grant usage on schema public to authenticated;

-- ---------------------------------------------------------------------------
-- Complete authenticated profile: no user-id parameter (self only).
-- ---------------------------------------------------------------------------
create function app_private.complete_profile(p_first_name text, p_last_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_first text := btrim(p_first_name);
  v_last text := btrim(p_last_name);
  v_profile jsonb;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if v_first is null or char_length(v_first) not between 1 and 80
     or v_last is null or char_length(v_last) not between 1 and 80 then
    raise exception 'First and last names must each be 1–80 characters' using errcode = '22023';
  end if;

  update public.profiles
  set first_name = v_first,
      last_name = v_last,
      name_confirmed_at = coalesce(name_confirmed_at, now()),
      updated_at = now()
  where user_id = v_actor
  returning jsonb_build_object(
    'user_id', user_id, 'first_name', first_name,
    'last_name', last_name, 'name_confirmed_at', name_confirmed_at
  ) into v_profile;

  if v_profile is null then
    raise exception 'User profile not found; please sign in again' using errcode = 'P0002';
  end if;
  return v_profile;
end;
$$;

create function public.complete_profile(p_first_name text, p_last_name text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.complete_profile(p_first_name, p_last_name);
$$;

-- ---------------------------------------------------------------------------
-- Create group; owner membership created in the same transaction.
-- ---------------------------------------------------------------------------
create function app_private.create_group(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_group_id uuid;
  v_name text := btrim(p_name);
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if v_name is null or char_length(v_name) not between 2 and 80 then
    raise exception 'Group name must be 2–80 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where user_id = v_actor) then
    raise exception 'Complete account creation first' using errcode = 'P0002';
  end if;

  insert into public.groups(name, owner_user_id)
  values (v_name, v_actor)
  returning id into v_group_id;

  insert into public.group_members(group_id, user_id, role)
  values (v_group_id, v_actor, 'owner');

  return v_group_id;
end;
$$;

create function public.create_group(p_name text)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select app_private.create_group(p_name);
$$;

-- ---------------------------------------------------------------------------
-- Create invite: owner-only. Token is shown ONCE; SHA-256 hash stored.
-- Two gen_random_uuid values provide ~244 bits of unpredictable token bits.
-- There is no payment or email integration in this phase.
-- ---------------------------------------------------------------------------
create function app_private.create_group_invite(
  p_group_id uuid,
  p_max_uses integer,
  p_expiry_hours integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_token text;
  v_invite_id uuid;
  v_expires_at timestamptz;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_group_id is null then raise exception 'Group required' using errcode = '22023'; end if;
  if p_max_uses is null or p_max_uses not between 1 and 1000
     or p_expiry_hours is null or p_expiry_hours not between 1 and 720 then
    raise exception 'max_uses must be 1–1000 and expiry_hours 1–720' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.groups g
    join public.group_members gm
      on gm.group_id = g.id and gm.user_id = v_actor
    where g.id = p_group_id and g.archived_at is null
      and g.owner_user_id = v_actor and gm.role = 'owner' and gm.left_at is null
  ) then
    raise exception 'Only the active group owner may create invitations' using errcode = '42501';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
             || replace(gen_random_uuid()::text, '-', '');
  v_expires_at := now() + make_interval(hours => p_expiry_hours);
  insert into public.group_invites(group_id, created_by_user_id, token_hash,
                                   expires_at, max_uses)
  values (p_group_id, v_actor,
          encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
          v_expires_at, p_max_uses)
  returning id into v_invite_id;

  return jsonb_build_object(
    'invite_id', v_invite_id, 'group_id', p_group_id,
    'token', v_token, 'expires_at', v_expires_at, 'max_uses', p_max_uses
  );
end;
$$;

create function public.create_group_invite(
  p_group_id uuid,
  p_max_uses integer default 25,
  p_expiry_hours integer default 168
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app_private.create_group_invite(p_group_id, p_max_uses, p_expiry_hours);
$$;

-- ---------------------------------------------------------------------------
-- Join with token; invitation row locked for concurrent use-count safety.
-- Re-using a valid invitation as an active member does not consume a use.
-- Tokens are not stored in plaintext and never appear in notifications.
-- ---------------------------------------------------------------------------
create function app_private.join_group(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_invite public.group_invites%rowtype;
  v_group_id uuid;
  v_joined_id uuid;
  v_member_name text;
  v_owner_id uuid;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'Invitation link is invalid' using errcode = '22023';
  end if;

  select * into v_invite
  from public.group_invites
  where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
  for update;

  if not found or v_invite.revoked_at is not null or v_invite.expires_at <= now()
     or v_invite.uses >= v_invite.max_uses then
    raise exception 'Invitation is expired, unavailable, or invalid' using errcode = '22023';
  end if;

  select g.id, g.owner_user_id into v_group_id, v_owner_id
  from public.groups g
  where g.id = v_invite.group_id and g.archived_at is null;
  if v_group_id is null then
    raise exception 'Group is no longer available' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.group_members
    where group_id = v_group_id and user_id = v_actor and left_at is null
  ) then
    return v_group_id;
  end if;

  insert into public.group_members(group_id, user_id, role)
  values (v_group_id, v_actor, 'member')
  on conflict (group_id, user_id) do update
    set role = 'member', joined_at = now(), left_at = null
    where public.group_members.left_at is not null
  returning user_id into v_joined_id;

  -- Concurrent use of a *different* invitation can make this a no-op.
  if v_joined_id is null then return v_group_id; end if;

  update public.group_invites
  set uses = uses + 1
  where id = v_invite.id;

  select coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'A colleague')
  into v_member_name
  from public.profiles p where p.user_id = v_actor;

  if v_owner_id <> v_actor then
    insert into public.notifications(
      recipient_user_id, group_id, event_key, type, title, body, target_type, target_id
    ) values (
      v_owner_id, v_group_id,
      'group:' || v_group_id::text || ':joined:' || v_actor::text,
      'group_member_joined', 'New group member',
      coalesce(v_member_name, 'A colleague') || ' joined your group.',
      'group', v_group_id
    ) on conflict (recipient_user_id, event_key) do nothing;
  end if;

  return v_group_id;
end;
$$;

create function public.join_group(p_token text)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select app_private.join_group(p_token);
$$;

-- ---------------------------------------------------------------------------
-- Record bill and its shares, audit event, and participant notifications
-- atomically. Must include signed-in payer among attendees for V1.
-- Duplicate request_id returns original expense without new notifications,
-- provided the material request matches (prevents silent payload reuse).
-- ---------------------------------------------------------------------------
create function app_private.record_expense(
  p_group_id uuid,
  p_amount_paisa bigint,
  p_participant_user_ids uuid[],
  p_request_id uuid,
  p_description text,
  p_occurred_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_expense_id uuid;
  v_existing public.expenses%rowtype;
  v_count integer;
  v_unique_count integer;
  v_valid_count integer;
  v_payer_selected boolean;
  v_occurred_at timestamptz := coalesce(p_occurred_at, now());
  v_description text := nullif(btrim(p_description), '');
  v_name text;
  v_share_sum numeric;
begin
  if v_actor is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if p_group_id is null or p_request_id is null then
    raise exception 'Group and unique request ID are required' using errcode = '22023';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'Bill amount must be positive' using errcode = '22023';
  end if;
  if v_description is not null and char_length(v_description) > 240 then
    raise exception 'Description too long (max 240 characters)' using errcode = '22023';
  end if;
  if v_occurred_at > now() + interval '5 minutes'
     or v_occurred_at < now() - interval '31 days' then
    raise exception 'Session date must be within the last 31 days and not in the future'
      using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.groups g
    join public.group_members gm on gm.group_id = g.id
    where g.id = p_group_id and g.archived_at is null
      and gm.user_id = v_actor and gm.left_at is null
  ) then
    raise exception 'Only active group members may record an expense' using errcode = '42501';
  end if;

  select count(*)::integer, count(distinct u.user_id)::integer,
         coalesce(bool_or(u.user_id = v_actor), false)
  into v_count, v_unique_count, v_payer_selected
  from unnest(p_participant_user_ids) as u(user_id);

  if v_count = 0 or v_count <> v_unique_count or not v_payer_selected then
    raise exception 'Choose unique attendees, including yourself as payer'
      using errcode = '22023';
  end if;

  select count(*)::integer into v_valid_count
  from public.group_members gm
  where gm.group_id = p_group_id and gm.left_at is null
    and gm.user_id = any(p_participant_user_ids);
  if v_valid_count <> v_count then
    raise exception 'Every attendee must be an active member of this group'
      using errcode = '22023';
  end if;

  -- Existing idempotency token: compare original request, then return its ID.
  select * into v_existing from public.expenses e
  where e.created_by_user_id = v_actor and e.request_id = p_request_id;
  if found then
    if v_existing.group_id <> p_group_id
       or v_existing.amount_paisa <> p_amount_paisa
       or v_existing.paid_by_user_id <> v_actor
       or v_existing.description is distinct from v_description
       or (p_occurred_at is not null and v_existing.occurred_at <> p_occurred_at)
       or v_existing.voided_at is not null
       or (select array_agg(s.user_id order by s.user_id)
           from public.expense_shares s where s.expense_id = v_existing.id)
          is distinct from
          (select array_agg(u.user_id order by u.user_id)
           from unnest(p_participant_user_ids) u(user_id)) then
      raise exception 'This request ID was already used for a different expense'
        using errcode = '23505';
    end if;
    return v_existing.id;
  end if;

  insert into public.expenses(
    group_id, created_by_user_id, paid_by_user_id, amount_paisa,
    split_method, occurred_at, description, request_id
  ) values (
    p_group_id, v_actor, v_actor, p_amount_paisa,
    'equal', v_occurred_at, v_description, p_request_id
  ) on conflict (created_by_user_id, request_id) do nothing
  returning id into v_expense_id;

  if v_expense_id is null then
    -- A concurrent identical retry won the UNIQUE constraint race. Re-enter
    -- verification by fetching the now-committed request row.
    select * into v_existing from public.expenses e
    where e.created_by_user_id = v_actor and e.request_id = p_request_id;
    if not found or v_existing.group_id <> p_group_id
       or v_existing.amount_paisa <> p_amount_paisa
       or v_existing.paid_by_user_id <> v_actor
       or v_existing.description is distinct from v_description
       or (p_occurred_at is not null and v_existing.occurred_at <> p_occurred_at)
       or v_existing.voided_at is not null
       or (select array_agg(s.user_id order by s.user_id)
           from public.expense_shares s where s.expense_id = v_existing.id)
          is distinct from
          (select array_agg(u.user_id order by u.user_id)
           from unnest(p_participant_user_ids) u(user_id)) then
      raise exception 'This request ID was already used for a different expense'
        using errcode = '23505';
    end if;
    return v_existing.id;
  end if;

  insert into public.expense_shares(expense_id, group_id, user_id, share_paisa)
  select v_expense_id, p_group_id, attendee.user_id,
         (p_amount_paisa / v_count)::bigint
         + case when attendee.ordinal <= (p_amount_paisa % v_count) then 1 else 0 end
  from (
    select u.user_id,
           row_number() over (order by u.user_id) as ordinal
    from unnest(p_participant_user_ids) u(user_id)
  ) attendee;

  select coalesce(sum(s.share_paisa), 0) into v_share_sum
  from public.expense_shares s where s.expense_id = v_expense_id;
  if v_share_sum <> p_amount_paisa then
    raise exception 'Internal calculation mismatch: expense shares do not add up';
  end if;

  insert into public.expense_audit(
    expense_id, group_id, actor_user_id, operation, after_json
  ) values (
    v_expense_id, p_group_id, v_actor, 'created',
    jsonb_build_object(
      'amount_paisa', p_amount_paisa, 'paid_by_user_id', v_actor,
      'split_method', 'equal', 'occurred_at', v_occurred_at,
      'participants', (select jsonb_agg(jsonb_build_object('user_id', s.user_id,
                              'share_paisa', s.share_paisa) order by s.user_id)
                       from public.expense_shares s where s.expense_id = v_expense_id)
    )
  );

  select coalesce(nullif(btrim(p.first_name || ' ' || p.last_name), ''), 'A colleague')
  into v_name from public.profiles p where p.user_id = v_actor;

  insert into public.notifications(
    recipient_user_id, group_id, event_key, type, title, body,
    target_type, target_id
  )
  select s.user_id, p_group_id,
         'expense:' || v_expense_id::text || ':created',
         'expense_created', 'New chai session',
         coalesce(v_name, 'A colleague') || ' recorded a session. Your share: Rs. '
           || (s.share_paisa / 100)::text || '.'
           || lpad((s.share_paisa % 100)::text, 2, '0') || '.',
         'expense', v_expense_id
  from public.expense_shares s
  where s.expense_id = v_expense_id and s.user_id <> v_actor
  on conflict (recipient_user_id, event_key) do nothing;

  return v_expense_id;
end;
$$;

create function public.record_expense(
  p_group_id uuid,
  p_amount_paisa bigint,
  p_participant_user_ids uuid[],
  p_request_id uuid,
  p_description text default null,
  p_occurred_at timestamptz default null
)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select app_private.record_expense(
    p_group_id, p_amount_paisa, p_participant_user_ids,
    p_request_id, p_description, p_occurred_at
  );
$$;

-- ---------------------------------------------------------------------------
-- Group balance calculation: read-only, group membership validated inside.
-- Net positive: paid more than consumed; negative: owes the group.
-- Includes historical (departed) members' expenses in sums.
-- Not yet a month-end settlement/pay-to recommendation.
-- ---------------------------------------------------------------------------
create function app_private.get_group_balances(p_group_id uuid)
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
      and gm.left_at is null and g.archived_at is null
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

create function public.get_group_balances(p_group_id uuid)
returns table (
  user_id uuid,
  first_name text,
  last_name text,
  total_paid_paisa bigint,
  total_share_paisa bigint,
  net_paisa bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from app_private.get_group_balances(p_group_id);
$$;

-- ---------------------------------------------------------------------------
-- Notification inbox is read via existing Phase 3.2 SELECT + RLS policy.
-- Mark-read RPCs use recipient-only checks; reading != acknowledging actions.
-- ---------------------------------------------------------------------------
create function app_private.mark_notification_read(p_notification_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id and recipient_user_id = auth.uid();
  get diagnostics v_count = row_count;
  return v_count = 1;
end;
$$;

create function public.mark_notification_read(p_notification_id uuid)
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select app_private.mark_notification_read(p_notification_id);
$$;

create function app_private.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  update public.notifications set read_at = now()
  where recipient_user_id = auth.uid() and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create function public.mark_all_notifications_read()
returns integer
language sql
security invoker
set search_path = ''
as $$
  select app_private.mark_all_notifications_read();
$$;

-- ---------------------------------------------------------------------------
-- Explicit permissions for private implementations and public RPC wrappers.
-- PUBLIC is a PostgreSQL role alias meaning EVERYONE (including anon).
-- PostgreSQL defaults new functions to EXECUTE for PUBLIC: always revoke.
-- ---------------------------------------------------------------------------
revoke all on function app_private.complete_profile(text,text) from public, anon, authenticated;
revoke all on function app_private.create_group(text) from public, anon, authenticated;
revoke all on function app_private.create_group_invite(uuid,integer,integer) from public, anon, authenticated;
revoke all on function app_private.join_group(text) from public, anon, authenticated;
revoke all on function app_private.record_expense(uuid,bigint,uuid[],uuid,text,timestamptz) from public, anon, authenticated;
revoke all on function app_private.get_group_balances(uuid) from public, anon, authenticated;
revoke all on function app_private.mark_notification_read(uuid) from public, anon, authenticated;
revoke all on function app_private.mark_all_notifications_read() from public, anon, authenticated;

grant execute on function app_private.complete_profile(text,text) to authenticated;
grant execute on function app_private.create_group(text) to authenticated;
grant execute on function app_private.create_group_invite(uuid,integer,integer) to authenticated;
grant execute on function app_private.join_group(text) to authenticated;
grant execute on function app_private.record_expense(uuid,bigint,uuid[],uuid,text,timestamptz) to authenticated;
grant execute on function app_private.get_group_balances(uuid) to authenticated;
grant execute on function app_private.mark_notification_read(uuid) to authenticated;
grant execute on function app_private.mark_all_notifications_read() to authenticated;

revoke all on function public.complete_profile(text,text) from public, anon, authenticated;
revoke all on function public.create_group(text) from public, anon, authenticated;
revoke all on function public.create_group_invite(uuid,integer,integer) from public, anon, authenticated;
revoke all on function public.join_group(text) from public, anon, authenticated;
revoke all on function public.record_expense(uuid,bigint,uuid[],uuid,text,timestamptz) from public, anon, authenticated;
revoke all on function public.get_group_balances(uuid) from public, anon, authenticated;
revoke all on function public.mark_notification_read(uuid) from public, anon, authenticated;
revoke all on function public.mark_all_notifications_read() from public, anon, authenticated;

grant execute on function public.complete_profile(text,text) to authenticated;
grant execute on function public.create_group(text) to authenticated;
grant execute on function public.create_group_invite(uuid,integer,integer) to authenticated;
grant execute on function public.join_group(text) to authenticated;
grant execute on function public.record_expense(uuid,bigint,uuid[],uuid,text,timestamptz) to authenticated;
grant execute on function public.get_group_balances(uuid) to authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- Explicitly preserve denial of direct client writes from Phase 3.2.
revoke insert, update, delete, truncate, references, trigger on
  public.profiles, public.groups, public.group_members, public.group_invites,
  public.expenses, public.expense_shares, public.expense_audit,
  public.notifications
from public, anon, authenticated;

commit;
