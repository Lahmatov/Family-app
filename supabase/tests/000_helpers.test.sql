-- Test helpers shared by all pgTAP files. This file runs first (alphabetical
-- order) and COMMITs the `tests` schema so later files can use it.
create extension if not exists pgtap with schema extensions;

create schema if not exists tests;
grant usage on schema tests to anon, authenticated;

create or replace function tests.create_user(p_email text, p_name text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_id, lower(p_email), jsonb_build_object('display_name', coalesce(p_name, p_email)));
  return v_id;
end
$$;

create or replace function tests.user_email(p_user uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select email from auth.users where id = p_user
$$;

-- Become `authenticated` with the given user and assurance level.
create or replace function tests.login(p_user uuid, p_aal text default 'aal2')
returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'role', 'authenticated', 'aal', p_aal, 'email', tests.user_email(p_user)
  )::text, true);
  perform set_config('role', 'authenticated', true);
end
$$;

create or replace function tests.login_anon() returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end
$$;

-- Back to the test superuser.
create or replace function tests.logout() returns void
language plpgsql
set search_path = ''
as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- Add a member directly (bypassing invitations) for test setup.
create or replace function tests.add_member(p_family uuid, p_user uuid, p_role public.member_role)
returns void
language sql security definer
set search_path = ''
as $$
  insert into public.family_members (family_id, user_id, role) values (p_family, p_user, p_role)
$$;

-- Create a family owned by p_admin (runs create_family as that user).
create or replace function tests.create_family(p_admin uuid, p_name text default 'Test family', p_currency text default 'EUR')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_family uuid;
begin
  perform tests.login(p_admin);
  v_family := public.create_family(p_name, p_currency);
  perform tests.logout();
  return v_family;
end
$$;

create or replace function tests.category(p_family uuid, p_key text)
returns uuid
language sql security definer
set search_path = ''
as $$
  select id from public.categories where family_id = p_family and system_key = p_key
$$;

-- Named ids stored in transaction-local settings so they are readable from
-- inside dollar-quoted SQL passed to throws_ok / lives_ok and by any role.
create or replace function tests.set_id(p_name text, p_id uuid) returns uuid
language sql
set search_path = ''
as $$
  select set_config('tests.' || p_name, p_id::text, true)::uuid
$$;

create or replace function tests.id(p_name text) returns uuid
language sql stable
set search_path = ''
as $$
  select current_setting('tests.' || p_name)::uuid
$$;

grant execute on all functions in schema tests to anon, authenticated;

select plan(1);
select ok(true, 'test helpers installed');
select * from finish();
