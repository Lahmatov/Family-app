-- =============================================================================
-- Critical actions with second-admin approval ("four-eyes" principle) and
-- email-bound invitations.
--
-- Rule: when a family has 2+ admins, a critical action requested by one admin
-- is executed only after ANOTHER admin approves it. With a single admin the
-- action executes immediately (there is nobody to ask).
-- =============================================================================

create type public.approval_action as enum (
  'invite_member',   -- payload: {email, role}
  'remove_member',   -- payload: {user_id}
  'change_role',     -- payload: {user_id, role}
  'delete_family'    -- payload: {}
);

create type public.approval_status as enum ('pending', 'executed', 'rejected', 'cancelled');

create table public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  action public.approval_action not null,
  payload jsonb not null default '{}'::jsonb,
  status public.approval_status not null default 'pending',
  requested_by uuid references auth.users (id) on delete set null,
  decided_by uuid references auth.users (id) on delete set null,
  decided_at timestamptz,
  expires_at timestamptz not null default now() + interval '7 days',
  created_at timestamptz not null default now()
);

create index approval_requests_family_idx on public.approval_requests (family_id, status);

create table public.family_invitations (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  email text not null check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 254),
  role public.member_role not null,
  invited_by uuid references auth.users (id) on delete set null,
  approval_id uuid references public.approval_requests (id) on delete set null,
  expires_at timestamptz not null default now() + interval '14 days',
  accepted_at timestamptz,
  declined_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index family_invitations_open_uniq
  on public.family_invitations (family_id, email)
  where accepted_at is null and declined_at is null;

-- -----------------------------------------------------------------------------
-- Payload validation
-- -----------------------------------------------------------------------------
create function private.validate_approval_payload(
  p_family uuid, p_action public.approval_action, p_payload jsonb
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_email text;
  v_user uuid;
  v_role public.member_role;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be an object' using errcode = '22023';
  end if;

  case p_action
    when 'invite_member' then
      v_email := lower(btrim(p_payload ->> 'email'));
      v_role := (p_payload ->> 'role')::public.member_role;
      if v_email is null or v_role is null then
        raise exception 'email and role required' using errcode = '22023';
      end if;
      if exists (
        select 1 from public.family_members fm join auth.users u on u.id = fm.user_id
        where fm.family_id = p_family and lower(u.email) = v_email
      ) then
        raise exception 'already a member' using errcode = '23505';
      end if;
      return jsonb_build_object('email', v_email, 'role', v_role);

    when 'remove_member' then
      v_user := (p_payload ->> 'user_id')::uuid;
      if v_user is null or not private.is_member(p_family, v_user) then
        raise exception 'unknown member' using errcode = '22023';
      end if;
      return jsonb_build_object('user_id', v_user);

    when 'change_role' then
      v_user := (p_payload ->> 'user_id')::uuid;
      v_role := (p_payload ->> 'role')::public.member_role;
      if v_user is null or v_role is null or not private.is_member(p_family, v_user) then
        raise exception 'user_id and role required' using errcode = '22023';
      end if;
      return jsonb_build_object('user_id', v_user, 'role', v_role);

    when 'delete_family' then
      return '{}'::jsonb;
  end case;
end
$$;

-- -----------------------------------------------------------------------------
-- Execution (only ever called from request_action / approve_request)
-- -----------------------------------------------------------------------------
create function private.execute_approval(p_request public.approval_requests) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_role public.member_role;
  v_current public.member_role;
begin
  case p_request.action
    when 'invite_member' then
      insert into public.family_invitations (family_id, email, role, invited_by, approval_id)
      values (
        p_request.family_id,
        p_request.payload ->> 'email',
        (p_request.payload ->> 'role')::public.member_role,
        p_request.requested_by,
        p_request.id
      );

    when 'remove_member' then
      v_user := (p_request.payload ->> 'user_id')::uuid;
      select role into v_current from public.family_members
        where family_id = p_request.family_id and user_id = v_user for update;
      if v_current is null then
        raise exception 'unknown member' using errcode = '22023';
      end if;
      if v_current = 'admin' and private.admin_count(p_request.family_id) = 1 then
        raise exception 'cannot remove the last admin' using errcode = '23514';
      end if;
      delete from public.family_members where family_id = p_request.family_id and user_id = v_user;

    when 'change_role' then
      v_user := (p_request.payload ->> 'user_id')::uuid;
      v_role := (p_request.payload ->> 'role')::public.member_role;
      select role into v_current from public.family_members
        where family_id = p_request.family_id and user_id = v_user for update;
      if v_current is null then
        raise exception 'unknown member' using errcode = '22023';
      end if;
      if v_current = 'admin' and v_role <> 'admin' and private.admin_count(p_request.family_id) = 1 then
        raise exception 'cannot demote the last admin' using errcode = '23514';
      end if;
      update public.family_members set role = v_role
        where family_id = p_request.family_id and user_id = v_user;

    when 'delete_family' then
      delete from public.families where id = p_request.family_id;
  end case;
end
$$;

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

-- Returns {id, status}. status = 'executed' when no second admin exists.
create function public.request_action(
  p_family uuid, p_action public.approval_action, p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_req public.approval_requests;
begin
  perform private.require_role(p_family, 'admin');

  -- Serialise critical actions per family.
  perform 1 from public.families where id = p_family for update;

  if (select count(*) from public.approval_requests
      where family_id = p_family and status = 'pending') >= 50 then
    raise exception 'too many pending requests' using errcode = '54000';
  end if;

  v_payload := private.validate_approval_payload(p_family, p_action, p_payload);

  insert into public.approval_requests (family_id, action, payload, requested_by)
  values (p_family, p_action, v_payload, auth.uid())
  returning * into v_req;

  perform private.audit(p_family, 'approval.requested', 'approval_request', v_req.id,
    jsonb_build_object('action', p_action, 'payload', v_payload));

  if private.admin_count(p_family) = 1 then
    update public.approval_requests
      set status = 'executed', decided_by = auth.uid(), decided_at = now()
      where id = v_req.id
      returning * into v_req;
    perform private.audit(p_family, 'approval.auto_executed', 'approval_request', v_req.id,
      jsonb_build_object('action', p_action));
    perform private.execute_approval(v_req);
  end if;

  return jsonb_build_object('id', v_req.id, 'status', v_req.status);
end
$$;

create function public.approve_request(p_request uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_req public.approval_requests;
begin
  perform private.require_mfa();

  select * into v_req from public.approval_requests where id = p_request for update;
  if v_req.id is null or not private.has_role(v_req.family_id, 'admin') then
    -- Same error whether it doesn't exist or isn't yours: no enumeration.
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'request is not pending' using errcode = '55000';
  end if;
  if v_req.expires_at < now() then
    raise exception 'request expired' using errcode = '55000';
  end if;
  if v_req.requested_by = auth.uid() then
    raise exception 'a second admin must approve' using errcode = '42501';
  end if;

  update public.approval_requests
    set status = 'executed', decided_by = auth.uid(), decided_at = now()
    where id = v_req.id
    returning * into v_req;

  perform private.audit(v_req.family_id, 'approval.approved', 'approval_request', v_req.id,
    jsonb_build_object('action', v_req.action));

  -- delete_family removes the audit trail with the family; that is intended.
  perform private.execute_approval(v_req);
end
$$;

-- Another admin rejects, or the requester cancels.
create function public.reject_request(p_request uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_req public.approval_requests;
  v_status public.approval_status;
begin
  perform private.require_mfa();

  select * into v_req from public.approval_requests where id = p_request for update;
  if v_req.id is null or not private.has_role(v_req.family_id, 'admin') then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'request is not pending' using errcode = '55000';
  end if;

  v_status := case when v_req.requested_by = auth.uid() then 'cancelled' else 'rejected' end;

  update public.approval_requests
    set status = v_status, decided_by = auth.uid(), decided_at = now()
    where id = v_req.id;

  perform private.audit(v_req.family_id, 'approval.' || v_status::text, 'approval_request', v_req.id,
    jsonb_build_object('action', v_req.action));
end
$$;

-- The invitee accepts. The invitation is bound to the verified email in the JWT.
create function public.accept_invitation(p_invitation uuid) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_inv public.family_invitations;
  v_email text := lower(auth.jwt() ->> 'email');
begin
  perform private.require_mfa();

  select * into v_inv from public.family_invitations where id = p_invitation for update;
  if v_inv.id is null or v_email is null or v_inv.email <> v_email then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;
  if v_inv.accepted_at is not null or v_inv.declined_at is not null or v_inv.expires_at < now() then
    raise exception 'invitation is no longer valid' using errcode = '55000';
  end if;

  insert into public.family_members (family_id, user_id, role)
  values (v_inv.family_id, auth.uid(), v_inv.role)
  on conflict (family_id, user_id) do nothing;

  update public.family_invitations set accepted_at = now() where id = v_inv.id;

  perform private.audit(v_inv.family_id, 'member.joined', 'user', auth.uid(),
    jsonb_build_object('role', v_inv.role, 'invitation_id', v_inv.id));

  return v_inv.family_id;
end
$$;

create function public.decline_invitation(p_invitation uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  update public.family_invitations
    set declined_at = now()
    where id = p_invitation and email = v_email
      and accepted_at is null and declined_at is null;

  if not found then
    raise exception 'invitation not found' using errcode = 'P0002';
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- RLS & privileges
-- -----------------------------------------------------------------------------
alter table public.approval_requests enable row level security;
alter table public.family_invitations enable row level security;

create policy approval_requests_select on public.approval_requests for select to authenticated
  using (private.has_role(family_id, 'admin'));

-- Admins see the family's invitations; invitees see invitations to their email
-- (needed to show "You were invited to ..." before joining).
create policy family_invitations_select on public.family_invitations for select to authenticated
  using (
    private.has_role(family_id, 'admin')
    or (email = lower(auth.jwt() ->> 'email') and accepted_at is null and declined_at is null
        and expires_at > now())
  );

revoke all on public.approval_requests, public.family_invitations from anon, authenticated;
grant select on public.approval_requests, public.family_invitations to authenticated;

revoke all on function private.validate_approval_payload(uuid, public.approval_action, jsonb) from public, anon, authenticated;
revoke all on function private.execute_approval(public.approval_requests) from public, anon, authenticated;

revoke all on function public.request_action(uuid, public.approval_action, jsonb) from public, anon;
revoke all on function public.approve_request(uuid) from public, anon;
revoke all on function public.reject_request(uuid) from public, anon;
revoke all on function public.accept_invitation(uuid) from public, anon;
revoke all on function public.decline_invitation(uuid) from public, anon;
grant execute on function public.request_action(uuid, public.approval_action, jsonb) to authenticated;
grant execute on function public.approve_request(uuid) to authenticated;
grant execute on function public.reject_request(uuid) to authenticated;
grant execute on function public.accept_invitation(uuid) to authenticated;
grant execute on function public.decline_invitation(uuid) to authenticated;
