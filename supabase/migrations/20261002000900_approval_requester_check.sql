-- Security review fix: an approval request is executed on behalf of its requester,
-- so the requester must still be an admin of the family at approval time. Without
-- this, a request made by an admin who was demoted or removed in the meantime
-- (for instance after their account was compromised) could still be approved
-- by the remaining admin and would then execute with the old privileges.

create or replace function public.approve_request(p_request uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_req public.approval_requests;
begin
  perform private.require_mfa();

  select * into v_req from public.approval_requests where id = p_request for update;
  if v_req.id is null or not private.has_role(v_req.family_id, 'admin') then
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

revoke all on function public.approve_request(uuid) from public, anon;
grant execute on function public.approve_request(uuid) to authenticated;
