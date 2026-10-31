-- Chai Khapa | Phase 3.2 | Explicit grants + row-level read security
-- Requires: 20261031120000_initial_core_schema.sql (Phase 3.1).
-- Financial and membership writes remain RPC-only (to be built in Phase 3.3).
-- Apply with Supabase CLI; this migration is atomic.

begin;

-- Preflight: reject running this migration before the Phase 3.1 schema exists.
do $$
begin
  if (
    select count(*)
    from pg_catalog.pg_tables
    where schemaname = 'public'
      and tablename in (
        'profiles', 'groups', 'group_members', 'group_invites',
        'expenses', 'expense_shares', 'expense_audit', 'notifications'
      )
  ) <> 8 then
    raise exception 'Chai Khapa Phase 3.1 schema is missing or incomplete; stop before applying Phase 3.2';
  end if;
end;
$$;

-- Explicit default-deny is important even if the project setting already
-- disabled automatic API table exposure. Policies never replace SQL GRANTs.
revoke all on public.profiles from public, anon, authenticated;
revoke all on public.groups from public, anon, authenticated;
revoke all on public.group_members from public, anon, authenticated;
revoke all on public.group_invites from public, anon, authenticated;
revoke all on public.expenses from public, anon, authenticated;
revoke all on public.expense_shares from public, anon, authenticated;
revoke all on public.expense_audit from public, anon, authenticated;
revoke all on public.notifications from public, anon, authenticated;

-- All eight tables stay RLS-protected (also true for 3.1).
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_invites enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_shares enable row level security;
alter table public.expense_audit enable row level security;
alter table public.notifications enable row level security;

-- Private helper schema is NOT in the Data API exposed-schemas list.
-- The PostgreSQL authenticated role needs USAGE + EXECUTE to evaluate these
-- functions inside policies. anon receives neither. This grants no table rights.
revoke all on schema app_private from public, anon, authenticated;
grant usage on schema app_private to authenticated;

-- Avoid recursive RLS on group_members: helper runs as postgres (its owner),
-- which bypasses RLS in Supabase unless FORCE RLS is later enabled.
-- auth.uid() comes from the signed-in request; no arbitrary user ID argument.
create function app_private.my_active_group_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select gm.group_id
  from public.group_members as gm
  where gm.user_id = (select auth.uid())
    and gm.left_at is null
$$;

-- History may reference a member who has since left a group. A currently active
-- member can still see their display name for past shared expenses, but a
-- former member cannot read the group once their own membership ends.
create function app_private.visible_profile_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select other.user_id
  from public.group_members as mine
  join public.group_members as other
    on other.group_id = mine.group_id
  where mine.user_id = (select auth.uid())
    and mine.left_at is null
  union
  select auth.uid()
  where auth.uid() is not null
$$;

-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default.
-- Explicitly undo that, including for unauthenticated clients.
revoke all on function app_private.my_active_group_ids() from public, anon, authenticated;
revoke all on function app_private.visible_profile_user_ids() from public, anon, authenticated;
grant execute on function app_private.my_active_group_ids() to authenticated;
grant execute on function app_private.visible_profile_user_ids() to authenticated;

-- Narrow table grants: only SELECT on the six reader-facing tables.
-- No INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, or TRIGGER privileges.
-- We allow SELECT * from profiles because its fields are only names and
-- onboarding timestamps: email is held in auth.users, not this table.
grant select on public.profiles to authenticated;
grant select on public.groups to authenticated;
grant select on public.group_members to authenticated;
grant select on public.expenses to authenticated;
grant select on public.expense_shares to authenticated;
grant select on public.notifications to authenticated;

-- No grants or policies for group_invites or expense_audit at this stage.
-- Phase 3.3 will add carefully reviewed RPCs to manage invites and expose
-- appropriate audit details. Client calls cannot read token hashes or JSON.

create policy "profiles_visible_to_me_or_shared_group"
  on public.profiles
  for select to authenticated
  using (user_id in (select app_private.visible_profile_user_ids()));

create policy "groups_visible_to_active_members"
  on public.groups
  for select to authenticated
  using (id in (select app_private.my_active_group_ids()));

create policy "members_visible_within_active_groups"
  on public.group_members
  for select to authenticated
  using (group_id in (select app_private.my_active_group_ids()));

create policy "expenses_visible_within_active_groups"
  on public.expenses
  for select to authenticated
  using (group_id in (select app_private.my_active_group_ids()));

create policy "shares_visible_within_active_groups"
  on public.expense_shares
  for select to authenticated
  using (group_id in (select app_private.my_active_group_ids()));

create policy "notifications_only_the_recipient"
  on public.notifications
  for select to authenticated
  using (recipient_user_id = (select auth.uid()));

-- Important: direct client writes, including read_at changes, remain denied.
-- Phase 3.3 implements authenticated RPC functions for all mutations.
-- Only app_private helper EXECUTEs are granted in this migration.

commit;
