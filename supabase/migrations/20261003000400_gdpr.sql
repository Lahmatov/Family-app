-- =============================================================================
-- GDPR: right of access / portability (export_my_data), right to erasure
-- (account_erasure_plan + delete_my_account) and data minimisation.
-- =============================================================================

-- Bug fix found while testing erasure: a family with a vault item could not be deleted. vault_items had no
-- foreign key to families of its own, only the RESTRICT one to vault_keys, which blocked the cascade that
-- removes the keys. Items now cascade with their family, and the key constraint is NO ACTION (checked at the
-- end of the statement, after both were removed by the cascade) so a key still cannot be deleted under items.
alter table public.vault_items drop constraint vault_items_key_id_family_id_fkey;
alter table public.vault_items add constraint vault_items_key_id_family_id_fkey
  foreign key (key_id, family_id) references public.vault_keys (id, family_id) on delete no action;
alter table public.vault_items add constraint vault_items_family_id_fkey
  foreign key (family_id) references public.families (id) on delete cascade;

-- Erasure nulls audit_log.actor_id through the FK (on delete set null). That is the one
-- update the append-only guard must allow: nothing else may change.
create or replace function private.audit_log_immutable() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  -- Cascade from deleting the whole family.
  if tg_op = 'DELETE' and old.family_id is not null
     and not exists (select 1 from public.families where id = old.family_id) then
    return old;
  end if;
  -- Erasure of a person: the actor is anonymised, the record itself stays.
  if tg_op = 'UPDATE' and old.actor_id is not null and new.actor_id is null
     and (to_jsonb(new) - 'actor_id') = (to_jsonb(old) - 'actor_id') then
    return new;
  end if;
  raise exception 'audit_log is append-only' using errcode = '42501';
end
$$;

-- Data minimisation: the invitee's e-mail address (a third party) is not copied into the
-- immutable audit log. Same function as before except for `v_payload - 'email'`.
create or replace function public.request_action(
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
    jsonb_build_object('action', p_action, 'payload', v_payload - 'email'));

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

-- -----------------------------------------------------------------------------
-- Access / portability: everything the caller may read, as one JSON document.
-- SECURITY INVOKER on purpose: row level security decides what is included, so
-- private items of other people never appear, and a new family table is covered
-- automatically as soon as it has a family_id column.
-- -----------------------------------------------------------------------------
create function public.export_my_data() returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  r record;
  result jsonb;
  rows jsonb;
begin
  if auth.uid() is null or coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    raise exception 'second factor required' using errcode = '28000';
  end if;

  result := jsonb_build_object(
    'exported_at', now(),
    'user_id', auth.uid(),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'families', (select coalesce(jsonb_agg(to_jsonb(f)), '[]') from public.families f));

  for r in
    select c.table_name
    from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'family_id' and t.table_type = 'BASE TABLE'
    order by c.table_name
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', r.table_name) into rows;
    result := result || jsonb_build_object(r.table_name, rows);
  end loop;
  return result;
end
$$;

-- -----------------------------------------------------------------------------
-- Erasure, step 1: what stands in the way and which stored files would be orphaned.
-- Files can only be removed through the Storage API (deleting rows from storage.objects
-- leaves the bytes behind), so the app deletes them before step 2, while it can still sign in.
-- -----------------------------------------------------------------------------
create function public.account_erasure_plan() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_blockers jsonb;
  v_files jsonb;
begin
  -- SECURITY DEFINER so that files whose parent row is hidden or gone are listed too; everything is scoped
  -- to the caller's own memberships.
  perform private.require_mfa();

  with mine as (
    select fm.family_id, fm.role,
           (select count(*) from public.family_members m where m.family_id = fm.family_id) as members,
           (select count(*) from public.family_members m where m.family_id = fm.family_id and m.role = 'admin') as admins
    from public.family_members fm where fm.user_id = auth.uid()
  )
  select coalesce(jsonb_agg(jsonb_build_object('family_id', f.id, 'name', f.name)), '[]') into v_blockers
  from mine join public.families f on f.id = mine.family_id
  where mine.role = 'admin' and mine.admins = 1 and mine.members > 1;

  with solo as (
    select fm.family_id from public.family_members fm
    where fm.user_id = auth.uid()
      and (select count(*) from public.family_members m where m.family_id = fm.family_id) = 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('bucket', x.bucket, 'name', x.name)), '[]') into v_files
  from (
    select 'family-files' as bucket, a.storage_path as name from public.attachments a
      where a.family_id in (select family_id from solo)
    union
    select 'vault', i.storage_path from public.vault_items i
      where i.family_id in (select family_id from solo)
         or i.key_id in (select k.id from public.vault_keys k where k.owner_id = auth.uid())
  ) x;

  return jsonb_build_object('blockers', v_blockers, 'files', v_files);
end
$$;

-- -----------------------------------------------------------------------------
-- Erasure, step 2: leave every family (the last member takes the family with them),
-- delete personal vault items and invitations to this address, then the account.
-- A sole admin of a family with other members must hand over first (same rule as leaving).
-- -----------------------------------------------------------------------------
create function public.delete_my_account() returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  r record;
begin
  perform private.require_mfa();

  select lower(email) into v_email from auth.users where id = v_uid;

  for r in select family_id from public.family_members where user_id = v_uid loop
    perform public.leave_family(r.family_id);
  end loop;

  -- vault_items.key_id is ON DELETE RESTRICT: personal items must go before the personal key does.
  delete from public.vault_items
  where key_id in (select id from public.vault_keys where owner_id = v_uid);

  delete from public.family_invitations where email = v_email;
  update public.approval_requests set payload = payload - 'email' where payload ->> 'email' = v_email;

  delete from auth.users where id = v_uid;
end
$$;

revoke all on function public.export_my_data() from public, anon;
revoke all on function public.account_erasure_plan() from public, anon;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.export_my_data() to authenticated;
grant execute on function public.account_erasure_plan() to authenticated;
grant execute on function public.delete_my_account() to authenticated;
