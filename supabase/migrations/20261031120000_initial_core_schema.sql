-- Chai Khapa | Phase 3.1 | Initial core schema
-- Database: Supabase PostgreSQL (public schema + a private trigger function).
-- This migration intentionally creates NO API-facing RLS policies or financial RPCs.
-- Client roles have NO table privileges until Phase 3.2.
-- Safe for a fresh chai-khapa-prod Supabase project; versioned, apply ONCE.

begin;

-- ---------------------------------------------------------------------------
-- 0. Internal functions: schema is intentionally NOT exposed by the Data API.
-- ---------------------------------------------------------------------------
create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Profiles: Supabase Auth remains the source of truth for identity/email.
-- A profile may be incomplete until the user confirms their first/last name.
-- ---------------------------------------------------------------------------
create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  first_name text,
  last_name text,
  name_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_names_together_check check (
    (first_name is null and last_name is null)
    or (
      first_name is not null and last_name is not null
      and length(btrim(first_name)) between 1 and 80
      and length(btrim(last_name)) between 1 and 80
    )
  ),
  constraint profiles_confirmation_check check (
    name_confirmed_at is null or (first_name is not null and last_name is not null)
  )
);

comment on table public.profiles is
  'Chai Khapa user names. Account identity/email are managed by Supabase Auth.';

-- ---------------------------------------------------------------------------
-- 2. Groups and memberships. Membership rows are retained after someone leaves,
-- because historical expenses must continue to reference past participants.
-- ---------------------------------------------------------------------------
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_user_id uuid not null references public.profiles(user_id) on delete restrict,
  timezone text not null default 'Asia/Karachi',
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint groups_name_check check (length(btrim(name)) between 2 and 80),
  constraint groups_timezone_check check (length(btrim(timezone)) between 1 and 80),
  constraint groups_archived_check check (archived_at is null or archived_at >= created_at)
);

create table public.group_members (
  group_id uuid not null references public.groups(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (group_id, user_id),
  constraint group_members_role_check check (role in ('owner', 'member')),
  constraint group_members_left_check check (left_at is null or left_at >= joined_at)
);

-- A group cannot have two simultaneously active owners. The create_group RPC
-- (Phase 3.3) will create the group and its owner membership atomically.
create unique index group_members_one_active_owner_idx
  on public.group_members(group_id)
  where role = 'owner' and left_at is null;

create index group_members_by_user_idx
  on public.group_members(user_id, group_id);

-- ---------------------------------------------------------------------------
-- 3. Invitations. Only hashes of high-entropy invitation tokens are stored.
-- No plaintext invitation token is kept in the database.
-- ---------------------------------------------------------------------------
create table public.group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  created_by_user_id uuid not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  max_uses integer not null default 25,
  uses integer not null default 0,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint group_invites_issuer_fk foreign key (group_id, created_by_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint group_invites_hash_check check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint group_invites_usage_check check (max_uses > 0 and uses >= 0 and uses <= max_uses),
  constraint group_invites_expiry_check check (expires_at > created_at),
  constraint group_invites_revocation_check check (revoked_at is null or revoked_at >= created_at)
);

create index group_invites_by_group_idx
  on public.group_invites(group_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 4. Sessions/expenses. Money is a BIGINT number of PAISA, never floating point.
-- Future-proofed for custom shares without changing the base ledger table.
-- ---------------------------------------------------------------------------
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  created_by_user_id uuid not null,
  paid_by_user_id uuid not null,
  amount_paisa bigint not null,
  split_method text not null default 'equal',
  occurred_at timestamptz not null default now(),
  description text,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by_user_id uuid,
  constraint expenses_creator_member_fk foreign key (group_id, created_by_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint expenses_payer_member_fk foreign key (group_id, paid_by_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint expenses_voider_member_fk foreign key (group_id, voided_by_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint expenses_amount_check check (amount_paisa > 0),
  constraint expenses_split_method_check check (split_method in ('equal', 'custom')),
  constraint expenses_description_check check (
    description is null or length(description) <= 240
  ),
  constraint expenses_voided_consistency_check check (
    (voided_at is null and voided_by_user_id is null)
    or (voided_at is not null and voided_by_user_id is not null)
  ),
  constraint expenses_voided_time_check check (voided_at is null or voided_at >= created_at),
  -- Restrict duplicated request IDs from one creator (idempotency for retries).
  constraint expenses_creator_request_unique unique (created_by_user_id, request_id),
  -- Allows shares/audit records to assert they reference the SAME group.
  constraint expenses_id_group_unique unique (id, group_id)
);

create index expenses_group_date_idx
  on public.expenses(group_id, occurred_at desc, id desc)
  where voided_at is null;

create index expenses_payer_idx
  on public.expenses(paid_by_user_id, group_id, occurred_at desc)
  where voided_at is null;

create table public.expense_shares (
  expense_id uuid not null,
  group_id uuid not null,
  user_id uuid not null,
  share_paisa bigint not null,
  primary key (expense_id, user_id),
  constraint expense_shares_expense_group_fk foreign key (expense_id, group_id)
    references public.expenses(id, group_id) on delete restrict,
  constraint expense_shares_participant_fk foreign key (group_id, user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint expense_shares_nonnegative_check check (share_paisa >= 0)
);

create index expense_shares_by_user_idx
  on public.expense_shares(user_id, group_id, expense_id);

create index expense_shares_by_group_idx
  on public.expense_shares(group_id, user_id);

-- ---------------------------------------------------------------------------
-- 5. Audit log. Append-only behavior comes from later write-only RPCs and grants.
-- ---------------------------------------------------------------------------
create table public.expense_audit (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null,
  group_id uuid not null,
  actor_user_id uuid not null,
  operation text not null,
  before_json jsonb,
  after_json jsonb,
  created_at timestamptz not null default now(),
  constraint expense_audit_expense_group_fk foreign key (expense_id, group_id)
    references public.expenses(id, group_id) on delete restrict,
  constraint expense_audit_actor_fk foreign key (group_id, actor_user_id)
    references public.group_members(group_id, user_id) on delete restrict,
  constraint expense_audit_operation_check check (
    operation in ('created', 'updated', 'voided', 'restored')
  ),
  constraint expense_audit_data_check check (
    before_json is not null or after_json is not null
  )
);

create index expense_audit_by_expense_idx
  on public.expense_audit(expense_id, created_at desc, id desc);

-- ---------------------------------------------------------------------------
-- 6. Persistent notifications. Push/email will be delivery channels later;
-- this table is the authoritative in-app inbox.
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references public.profiles(user_id) on delete restrict,
  group_id uuid references public.groups(id) on delete restrict,
  event_key text not null,
  type text not null,
  title text not null,
  body text not null,
  target_type text,
  target_id uuid,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint notifications_event_unique unique (recipient_user_id, event_key),
  constraint notifications_event_key_check check (length(btrim(event_key)) between 1 and 180),
  constraint notifications_type_check check (length(btrim(type)) between 1 and 60),
  constraint notifications_title_check check (length(btrim(title)) between 1 and 160),
  constraint notifications_body_check check (length(body) <= 1000),
  constraint notifications_target_check check (
    (target_type is null and target_id is null)
    or (target_type in ('group', 'expense', 'settlement', 'payment') and target_id is not null)
  ),
  constraint notifications_read_time_check check (read_at is null or read_at >= created_at)
);

create index notifications_inbox_idx
  on public.notifications(recipient_user_id, created_at desc, id desc);

create index notifications_unread_idx
  on public.notifications(recipient_user_id, created_at desc, id desc)
  where read_at is null;

-- ---------------------------------------------------------------------------
-- 7. Sign-in profile bootstrap. This is intentionally the only server-side
-- behavior in Phase 3.1: a first-time Google sign-in gets a blank profile.
-- Users will confirm first and last names via the Phase 3.3 profile workflow.
-- ---------------------------------------------------------------------------
create function app_private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function app_private.handle_new_auth_user() from public, anon, authenticated;

create trigger chai_khapa_auth_user_created
  after insert on auth.users
  for each row execute function app_private.handle_new_auth_user();

-- Backfill any users who signed in before this migration was deployed.
insert into public.profiles(user_id)
select id from auth.users
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 8. DENY BY DEFAULT: RLS and grants in SAME migration, with no client policies.
-- Phase 3.2 will explicitly add minimal grants + reviewed RLS policies.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_invites enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_shares enable row level security;
alter table public.expense_audit enable row level security;
alter table public.notifications enable row level security;

revoke all on table public.profiles from public, anon, authenticated;
revoke all on table public.groups from public, anon, authenticated;
revoke all on table public.group_members from public, anon, authenticated;
revoke all on table public.group_invites from public, anon, authenticated;
revoke all on table public.expenses from public, anon, authenticated;
revoke all on table public.expense_shares from public, anon, authenticated;
revoke all on table public.expense_audit from public, anon, authenticated;
revoke all on table public.notifications from public, anon, authenticated;

-- Deliberately NO authenticated SELECT/INSERT/UPDATE/DELETE grants yet.
-- Deliberately NO RLS policies yet. Database functions and policies follow.
commit;
