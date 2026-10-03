-- =============================================================================
-- Encrypted vault (end-to-end). The server stores ONLY ciphertext and public keys:
--   * vault_identities: each person's public X25519 key (the private key never leaves devices)
--   * vault_identity_backups: the private key encrypted with the person's recovery key
--   * vault_keys + vault_key_wraps: a family key and personal keys, each wrapped to its holders' public keys
--   * vault_items: per-document keys wrapped under a vault key, encrypted metadata, and a pointer to
--     the encrypted file in the `vault` Storage bucket
-- The cryptography is in FamilyCore (VaultCrypto) and is documented in docs/08-vault.md.
-- Row access is enforced by "do I hold a wrap of this key", so even a leaked JWT of a family member
-- who was removed gets nothing, and nobody (admins included) can read a personal item.
-- =============================================================================

create type public.vault_key_kind as enum ('family', 'personal');

create table public.vault_identities (
  user_id uuid primary key references auth.users (id) on delete cascade,
  public_key bytea not null check (octet_length(public_key) = 32),
  created_at timestamptz not null default now()
);

create table public.vault_identity_backups (
  user_id uuid primary key references auth.users (id) on delete cascade,
  blob bytea not null check (octet_length(blob) between 40 and 512),
  updated_at timestamptz not null default now()
);

create table public.vault_keys (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.vault_key_kind not null,
  owner_id uuid references auth.users (id) on delete cascade,
  version int not null default 1 check (version >= 1),
  -- set when a member left or lost access: an admin must rotate the family key
  rotation_needed boolean not null default false,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'personal') = (owner_id is not null)),
  unique (id, family_id)
);

create unique index vault_keys_family_version on public.vault_keys (family_id, version) where kind = 'family';
create unique index vault_keys_personal_owner on public.vault_keys (family_id, owner_id) where kind = 'personal';

create table public.vault_key_wraps (
  key_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  family_id uuid not null,
  wrapped bytea not null check (octet_length(wrapped) between 80 and 256),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (key_id, user_id),
  foreign key (key_id, family_id) references public.vault_keys (id, family_id) on delete cascade
);

create index vault_key_wraps_user_idx on public.vault_key_wraps (user_id);

create table public.vault_items (
  id uuid primary key,
  family_id uuid not null,
  key_id uuid not null,
  encrypted_meta bytea not null check (octet_length(encrypted_meta) between 30 and 4096),
  wrapped_item_key bytea not null check (octet_length(wrapped_item_key) between 40 and 256),
  storage_path text not null,
  size_bytes bigint not null check (size_bytes between 1 and 26214400),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}$'),
  check (split_part(storage_path, '/', 1) = family_id::text and split_part(storage_path, '/', 2) = id::text),
  foreign key (key_id, family_id) references public.vault_keys (id, family_id) on delete restrict
);

create index vault_items_key_idx on public.vault_items (key_id);
create index vault_items_family_idx on public.vault_items (family_id, created_at desc);

create trigger vault_items_updated_at before update on public.vault_items
for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Helpers and triggers
-- -----------------------------------------------------------------------------
create function private.holds_key(p_key uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select private.mfa_ok() and exists (
    select 1 from public.vault_key_wraps where key_id = p_key and user_id = auth.uid()
  )
$$;

-- A member who leaves (or drops below "adult") loses every wrap in that family, and the family key
-- is flagged for rotation: they may still hold the old key in memory or on a backup.
create function private.vault_member_left() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.role in ('admin', 'adult') then
    return new;
  end if;
  delete from public.vault_key_wraps where family_id = old.family_id and user_id = old.user_id;
  update public.vault_keys set rotation_needed = true where family_id = old.family_id and kind = 'family';
  return coalesce(new, old);
end
$$;

create trigger family_members_vault_cleanup after delete or update of role on public.family_members
for each row execute function private.vault_member_left();

-- Wraps are encrypted to the old public key; once the identity is reset they are dead weight.
create function private.vault_identity_reset() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.vault_key_wraps where user_id = old.user_id;
  return old;
end
$$;

create trigger vault_identities_reset after delete on public.vault_identities
for each row execute function private.vault_identity_reset();

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------
-- The client picks the key id: it is part of the encryption context of every wrap and item key, so it
-- must be known before anything is wrapped.
create function public.vault_create_key(p_key_id uuid, p_family uuid, p_kind public.vault_key_kind, p_wrapped_for_me bytea)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_key uuid;
begin
  perform private.require_role(p_family, 'adult');
  if not exists (select 1 from public.vault_identities where user_id = auth.uid()) then
    raise exception 'create your vault identity first' using errcode = '55000';
  end if;

  if p_kind = 'family' then
    if exists (select 1 from public.vault_keys where family_id = p_family and kind = 'family') then
      raise exception 'the family key already exists' using errcode = '23505';
    end if;
    insert into public.vault_keys (id, family_id, kind) values (p_key_id, p_family, 'family') returning id into v_key;
  else
    insert into public.vault_keys (id, family_id, kind, owner_id) values (p_key_id, p_family, 'personal', auth.uid())
    returning id into v_key;
  end if;

  insert into public.vault_key_wraps (key_id, user_id, family_id, wrapped)
  values (v_key, auth.uid(), p_family, p_wrapped_for_me);

  perform private.audit(p_family, 'vault.key_created', 'vault_key', v_key, jsonb_build_object('kind', p_kind));
  return v_key;
end
$$;

-- A holder of the family key wraps it for another adult member (done on the holder's device).
create function public.vault_share_key(p_key uuid, p_user uuid, p_wrapped bytea) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_key public.vault_keys;
begin
  perform private.require_mfa();
  select * into v_key from public.vault_keys where id = p_key;
  if v_key.id is null or not private.holds_key(p_key) then
    raise exception 'key not found' using errcode = 'P0002';
  end if;
  perform private.require_role(v_key.family_id, 'adult');
  if v_key.kind <> 'family' then
    raise exception 'personal keys cannot be shared' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.family_members
    where family_id = v_key.family_id and user_id = p_user and role in ('admin', 'adult')
  ) then
    raise exception 'the recipient must be an adult member' using errcode = '42501';
  end if;
  if not exists (select 1 from public.vault_identities where user_id = p_user) then
    raise exception 'the recipient has no vault identity yet' using errcode = '55000';
  end if;

  insert into public.vault_key_wraps (key_id, user_id, family_id, wrapped)
  values (p_key, p_user, v_key.family_id, p_wrapped);

  perform private.audit(v_key.family_id, 'vault.key_shared', 'vault_key', p_key, jsonb_build_object('user_id', p_user));
end
$$;

-- After a member left: a new family key, wrapped only for the people who should keep access, and every
-- item key re-wrapped under it (the files themselves are untouched). All-or-nothing.
-- p_wraps:  [{"user_id": uuid, "wrapped": base64}]
-- p_items:  [{"id": uuid, "wrapped_item_key": base64}]  (must cover every item of the current key)
create function public.vault_rotate_family_key(p_new_key_id uuid, p_family uuid, p_wraps jsonb, p_items jsonb) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_old public.vault_keys;
  v_new uuid;
  v_wrap jsonb;
  v_item jsonb;
  v_user uuid;
  v_updated int;
  v_items int;
begin
  perform private.require_role(p_family, 'admin');
  if jsonb_typeof(p_wraps) <> 'array' or jsonb_typeof(p_items) <> 'array' then
    raise exception 'wraps and items must be arrays' using errcode = '22023';
  end if;

  select * into v_old from public.vault_keys
  where family_id = p_family and kind = 'family' order by version desc limit 1 for update;
  if v_old.id is null or not private.holds_key(v_old.id) then
    raise exception 'key not found' using errcode = 'P0002';
  end if;

  insert into public.vault_keys (id, family_id, kind, version) values (p_new_key_id, p_family, 'family', v_old.version + 1)
  returning id into v_new;

  for v_wrap in select * from jsonb_array_elements(p_wraps) loop
    v_user := (v_wrap ->> 'user_id')::uuid;
    if not exists (
      select 1 from public.family_members
      where family_id = p_family and user_id = v_user and role in ('admin', 'adult')
    ) or not exists (select 1 from public.vault_identities where user_id = v_user) then
      raise exception 'every recipient must be an adult member with a vault identity' using errcode = '42501';
    end if;
    insert into public.vault_key_wraps (key_id, user_id, family_id, wrapped)
    values (v_new, v_user, p_family, decode(v_wrap ->> 'wrapped', 'base64'));
  end loop;

  if not exists (select 1 from public.vault_key_wraps where key_id = v_new and user_id = auth.uid()) then
    raise exception 'the admin must keep access' using errcode = '22023';
  end if;

  select count(*) into v_items from public.vault_items where key_id = v_old.id;
  if v_items <> jsonb_array_length(p_items) then
    raise exception 'every item of the old key must be re-wrapped' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    update public.vault_items
      set key_id = v_new, wrapped_item_key = decode(v_item ->> 'wrapped_item_key', 'base64')
      where id = (v_item ->> 'id')::uuid and key_id = v_old.id and family_id = p_family;
    get diagnostics v_updated = row_count;
    if v_updated <> 1 then
      raise exception 'unknown item in the list' using errcode = '22023';
    end if;
  end loop;

  delete from public.vault_keys where id = v_old.id;  -- its wraps cascade
  perform private.audit(p_family, 'vault.key_rotated', 'vault_key', v_new,
    jsonb_build_object('version', v_old.version + 1, 'items', v_items));
  return v_new;
end
$$;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.vault_identities enable row level security;
alter table public.vault_identity_backups enable row level security;
alter table public.vault_keys enable row level security;
alter table public.vault_key_wraps enable row level security;
alter table public.vault_items enable row level security;

-- Public keys are visible to people in a shared family (needed to wrap keys for them).
create policy vault_identities_select on public.vault_identities for select to authenticated
  using (private.mfa_ok() and (user_id = auth.uid() or private.shares_family(user_id)));
create policy vault_identities_insert on public.vault_identities for insert to authenticated
  with check (private.mfa_ok() and user_id = auth.uid());
create policy vault_identities_delete on public.vault_identities for delete to authenticated
  using (private.mfa_ok() and user_id = auth.uid());

create policy vault_backups_select on public.vault_identity_backups for select to authenticated
  using (private.mfa_ok() and user_id = auth.uid());
create policy vault_backups_insert on public.vault_identity_backups for insert to authenticated
  with check (private.mfa_ok() and user_id = auth.uid());
create policy vault_backups_update on public.vault_identity_backups for update to authenticated
  using (private.mfa_ok() and user_id = auth.uid()) with check (private.mfa_ok() and user_id = auth.uid());
create policy vault_backups_delete on public.vault_identity_backups for delete to authenticated
  using (private.mfa_ok() and user_id = auth.uid());

create policy vault_keys_select on public.vault_keys for select to authenticated
  using (private.holds_key(id));
create policy vault_key_wraps_select on public.vault_key_wraps for select to authenticated
  using (private.mfa_ok() and user_id = auth.uid());

create policy vault_items_select on public.vault_items for select to authenticated
  using (private.holds_key(key_id) and private.has_role(family_id, 'adult'));
create policy vault_items_insert on public.vault_items for insert to authenticated
  with check (private.holds_key(key_id) and private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy vault_items_update on public.vault_items for update to authenticated
  using (private.holds_key(key_id) and private.has_role(family_id, 'adult'))
  with check (private.holds_key(key_id) and private.has_role(family_id, 'adult'));
create policy vault_items_delete on public.vault_items for delete to authenticated
  using (private.holds_key(key_id) and private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on public.vault_identities, public.vault_identity_backups, public.vault_keys,
  public.vault_key_wraps, public.vault_items from anon, authenticated;

grant select, delete on public.vault_identities to authenticated;
grant insert (user_id, public_key) on public.vault_identities to authenticated;
grant select, delete on public.vault_identity_backups to authenticated;
grant insert (user_id, blob) on public.vault_identity_backups to authenticated;
grant update (blob) on public.vault_identity_backups to authenticated;
grant select on public.vault_keys, public.vault_key_wraps to authenticated;
grant select, delete on public.vault_items to authenticated;
grant insert (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  on public.vault_items to authenticated;
grant update (encrypted_meta) on public.vault_items to authenticated;

revoke all on function private.holds_key(uuid) from public, anon;
grant execute on function private.holds_key(uuid) to authenticated;
revoke all on function private.vault_member_left() from public, anon, authenticated;
revoke all on function private.vault_identity_reset() from public, anon, authenticated;

revoke all on function public.vault_create_key(uuid, uuid, public.vault_key_kind, bytea) from public, anon;
revoke all on function public.vault_share_key(uuid, uuid, bytea) from public, anon;
revoke all on function public.vault_rotate_family_key(uuid, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.vault_create_key(uuid, uuid, public.vault_key_kind, bytea) to authenticated;
grant execute on function public.vault_share_key(uuid, uuid, bytea) to authenticated;
grant execute on function public.vault_rotate_family_key(uuid, uuid, jsonb, jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- Storage: encrypted blobs only, <family_id>/<item_id>
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vault', 'vault', false, 25 * 1024 * 1024, array['application/octet-stream'])
on conflict (id) do nothing;

create policy vault_objects_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'vault'
    and owner_id = auth.uid()::text
    and private.has_role(private.try_uuid((storage.foldername(name))[1]), 'adult')
  );

-- Readable only through a vault_items row the caller can see (RLS of vault_items applies here).
create policy vault_objects_select on storage.objects for select to authenticated
  using (bucket_id = 'vault' and exists (select 1 from public.vault_items i where i.storage_path = objects.name));

create policy vault_objects_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'vault'
    and (
      (owner_id = auth.uid()::text
        and private.has_role(private.try_uuid((storage.foldername(name))[1]), 'adult')
        and not exists (select 1 from public.vault_items i where i.storage_path = objects.name))
      or exists (
        select 1 from public.vault_items i
        where i.storage_path = objects.name and (i.created_by = auth.uid() or private.has_role(i.family_id, 'admin'))
      )
    )
  );

-- Who holds a key. Only a holder may ask; the answer is just user ids (no key material). The app uses it
-- to show which adults are still waiting for access and to whom a rotated key must be wrapped.
create function public.vault_key_holders(p_key uuid) returns setof uuid
language plpgsql stable security definer
set search_path = ''
as $$
begin
  perform private.require_mfa();
  if not private.holds_key(p_key) then
    raise exception 'key not found' using errcode = 'P0002';
  end if;
  return query select user_id from public.vault_key_wraps where key_id = p_key;
end
$$;

revoke all on function public.vault_key_holders(uuid) from public, anon;
grant execute on function public.vault_key_holders(uuid) to authenticated;
