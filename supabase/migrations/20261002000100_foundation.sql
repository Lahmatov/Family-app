-- =============================================================================
-- Foundation: profiles, families, membership, roles, audit log.
--
-- Security model (see docs/02-security.md):
--   * Every table in `public` has RLS enabled. Nothing is reachable by `anon`.
--   * Family data requires an MFA-verified session (JWT aal = 'aal2').
--   * Membership / roles are never written directly by clients. All changes go
--     through SECURITY DEFINER functions that validate and audit them.
--   * Helper functions live in the `private` schema, which is NOT exposed
--     through the REST API.
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------
create type public.member_role as enum ('admin', 'adult', 'child', 'guest');
create type public.app_locale as enum ('ru', 'en', 'pt-PT');

-- -----------------------------------------------------------------------------
-- Generic helpers
-- -----------------------------------------------------------------------------
create function private.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

-- True when the current session passed the second factor.
create function private.mfa_ok() returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
$$;

create function private.role_rank(p_role public.member_role) returns int
language sql immutable
set search_path = ''
as $$
  select case p_role
    when 'admin' then 40
    when 'adult' then 30
    when 'child' then 20
    when 'guest' then 10
  end
$$;

create function private.require_mfa() returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if not private.mfa_ok() then
    raise exception 'second factor required' using errcode = '28000';
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- Profiles
-- -----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 80),
  locale public.app_locale not null default 'ru',
  avatar_path text check (char_length(avatar_path) <= 512),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_updated_at before update on public.profiles
for each row execute function private.set_updated_at();

create function private.handle_new_user() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 80)
  )
  on conflict (id) do nothing;
  return new;
end
$$;

create trigger on_auth_user_created after insert on auth.users
for each row execute function private.handle_new_user();

-- -----------------------------------------------------------------------------
-- Families & membership
-- -----------------------------------------------------------------------------
create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  base_currency char(3) not null default 'EUR' check (base_currency ~ '^[A-Z]{3}$'),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger families_updated_at before update on public.families
for each row execute function private.set_updated_at();

create table public.family_members (
  family_id uuid not null references public.families (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.member_role not null,
  joined_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

create index family_members_user_idx on public.family_members (user_id);

-- -----------------------------------------------------------------------------
-- Membership helpers used by RLS policies
-- -----------------------------------------------------------------------------
-- Role of the current user in a family, or NULL. NULL also when MFA is missing,
-- which makes every policy built on top of it fail closed.
create function private.my_role(p_family uuid) returns public.member_role
language sql stable security definer
set search_path = ''
as $$
  select fm.role
  from public.family_members fm
  where fm.family_id = p_family
    and fm.user_id = auth.uid()
    and private.mfa_ok()
$$;

create function private.has_role(p_family uuid, p_min public.member_role) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(private.role_rank(private.my_role(p_family)) >= private.role_rank(p_min), false)
$$;

-- Is `p_user` in at least one family with the current user?
create function private.shares_family(p_user uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.mfa_ok() and exists (
    select 1
    from public.family_members me
    join public.family_members other on other.family_id = me.family_id
    where me.user_id = auth.uid() and other.user_id = p_user
  )
$$;

create function private.is_member(p_family uuid, p_user uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_members
    where family_id = p_family and user_id = p_user
  )
$$;

create function private.admin_count(p_family uuid) returns int
language sql stable security definer
set search_path = ''
as $$
  select count(*)::int from public.family_members
  where family_id = p_family and role = 'admin'
$$;

create function private.require_role(p_family uuid, p_min public.member_role) returns void
language plpgsql stable
set search_path = ''
as $$
begin
  perform private.require_mfa();
  if not private.has_role(p_family, p_min) then
    raise exception 'insufficient privileges' using errcode = '42501';
  end if;
end
$$;


-- -----------------------------------------------------------------------------
-- Audit log (append-only, written only by SECURITY DEFINER code)
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id bigint generated always as identity primary key,
  family_id uuid references public.families (id) on delete cascade,
  actor_id uuid references auth.users (id) on delete set null,
  action text not null check (char_length(action) <= 64),
  entity_type text check (char_length(entity_type) <= 64),
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_family_idx on public.audit_log (family_id, created_at desc);

create function private.audit(
  p_family uuid, p_action text, p_entity_type text, p_entity_id uuid, p_details jsonb default '{}'::jsonb
) returns void
language sql security definer
set search_path = ''
as $$
  insert into public.audit_log (family_id, actor_id, action, entity_type, entity_id, details)
  values (p_family, auth.uid(), p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb))
$$;

-- Defence in depth: even a superuser-less bug in a policy must not allow
-- rewriting history.
create function private.audit_log_immutable() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  -- The only allowed removal is the cascade from deleting the whole family.
  if tg_op = 'DELETE' and old.family_id is not null
     and not exists (select 1 from public.families where id = old.family_id) then
    return old;
  end if;
  raise exception 'audit_log is append-only' using errcode = '42501';
end
$$;

create trigger audit_log_no_update before update or delete on public.audit_log
for each row execute function private.audit_log_immutable();

-- -----------------------------------------------------------------------------
-- RPC: create a family. Caller becomes its first admin.
-- -----------------------------------------------------------------------------
create function public.create_family(p_name text, p_base_currency text default 'EUR')
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_family uuid;
begin
  perform private.require_mfa();

  if (select count(*) from public.family_members where user_id = auth.uid()) >= 5 then
    raise exception 'too many families' using errcode = '54000';
  end if;

  insert into public.families (name, base_currency, created_by)
  values (btrim(p_name), upper(p_base_currency), auth.uid())
  returning id into v_family;

  insert into public.family_members (family_id, user_id, role)
  values (v_family, auth.uid(), 'admin');

  perform private.audit(v_family, 'family.created', 'family', v_family,
    jsonb_build_object('name', btrim(p_name)));

  return v_family;
end
$$;

-- RPC: leave a family voluntarily.
create function public.leave_family(p_family uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.member_role;
  v_members int;
begin
  perform private.require_mfa();

  select role into v_role from public.family_members
  where family_id = p_family and user_id = auth.uid()
  for update;

  if v_role is null then
    raise exception 'not a member' using errcode = '42501';
  end if;

  select count(*) into v_members from public.family_members where family_id = p_family;

  if v_members = 1 then
    delete from public.families where id = p_family;
    return;
  end if;

  if v_role = 'admin' and private.admin_count(p_family) = 1 then
    raise exception 'last admin cannot leave; promote someone first' using errcode = '23514';
  end if;

  delete from public.family_members where family_id = p_family and user_id = auth.uid();
  perform private.audit(p_family, 'member.left', 'user', auth.uid());
end
$$;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.audit_log enable row level security;

-- Own profile is reachable without MFA (needed during onboarding / MFA setup).
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or private.shares_family(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy families_select on public.families for select to authenticated
  using (private.has_role(id, 'guest'));
create policy families_update on public.families for update to authenticated
  using (private.has_role(id, 'admin')) with check (private.has_role(id, 'admin'));

create policy family_members_select on public.family_members for select to authenticated
  using (private.has_role(family_id, 'guest'));

create policy audit_log_select on public.audit_log for select to authenticated
  using (private.has_role(family_id, 'admin'));

-- -----------------------------------------------------------------------------
-- Privileges (explicit; never rely on Supabase defaults)
-- -----------------------------------------------------------------------------
revoke all on public.profiles, public.families, public.family_members, public.audit_log
  from anon, authenticated;

grant select on public.profiles to authenticated;
grant update (display_name, locale, avatar_path) on public.profiles to authenticated;

grant select on public.families to authenticated;
grant update (name) on public.families to authenticated;

grant select on public.family_members to authenticated;
grant select on public.audit_log to authenticated;

-- Only the helpers referenced by RLS policies are executable by API roles.
-- Everything else in `private` runs exclusively inside SECURITY DEFINER code.
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function
  private.mfa_ok(),
  private.role_rank(public.member_role),
  private.my_role(uuid),
  private.has_role(uuid, public.member_role),
  private.shares_family(uuid)
to authenticated;

revoke all on function public.create_family(text, text) from public, anon;
revoke all on function public.leave_family(uuid) from public, anon;
grant execute on function public.create_family(text, text) to authenticated;
grant execute on function public.leave_family(uuid) to authenticated;
