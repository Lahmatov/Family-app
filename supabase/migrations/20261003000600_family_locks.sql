-- Review fix (CodeRabbit): approve_request and leave_family did not serialise with request_action, which takes
-- a lock on the family row. Two admins approving each other's "remove admin" requests at the same moment each
-- saw two admins and each removed the other, leaving none. Now every operation that can change the admin set
-- locks the family row first (order everywhere: family, then request, then member rows).

create or replace function public.approve_request(p_request uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_family uuid;
  v_req public.approval_requests;
begin
  perform private.require_mfa();

  select family_id into v_family from public.approval_requests where id = p_request;
  if v_family is null or not private.has_role(v_family, 'admin') then
    raise exception 'request not found' using errcode = 'P0002';
  end if;

  perform 1 from public.families where id = v_family for update;

  select * into v_req from public.approval_requests where id = p_request for update;
  if v_req.id is null then
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
  if v_req.requested_by is null or not exists (
    select 1 from public.family_members
    where family_id = v_req.family_id and user_id = v_req.requested_by and role = 'admin'
  ) then
    raise exception 'requester is no longer an admin' using errcode = '55000';
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

create or replace function public.leave_family(p_family uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_role public.member_role;
  v_members int;
begin
  perform private.require_mfa();

  perform 1 from public.families where id = p_family for update;

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

revoke all on function public.approve_request(uuid) from public, anon;
revoke all on function public.leave_family(uuid) from public, anon;
grant execute on function public.approve_request(uuid) to authenticated;
grant execute on function public.leave_family(uuid) to authenticated;
