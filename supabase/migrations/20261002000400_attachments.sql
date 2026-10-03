-- =============================================================================
-- Attachments (receipt photos etc.) and Storage access rules.
--
-- Object path convention:  <family_id>/<entity_type>/<random uuid>.<ext>
--
-- Reading an object requires a visible `attachments` row pointing at it. Since
-- `attachments` RLS delegates to the parent entity's RLS, a receipt of a
-- private expense is only readable by that expense's author.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'family-files', 'family-files', false, 20 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf']
)
on conflict (id) do nothing;

create type public.attachment_entity as enum ('transaction');

create function private.try_uuid(p text) returns uuid
language plpgsql immutable
set search_path = ''
as $$
begin
  return p::uuid;
exception when others then
  return null;
end
$$;

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  entity_type public.attachment_entity not null,
  entity_id uuid not null,
  storage_path text not null unique
    check (storage_path ~ '^[0-9a-f-]{36}/[a-z_]+/[0-9a-f-]{36}\.(jpg|jpeg|png|heic|webp|pdf)$'),
  mime_type text not null
    check (mime_type in ('image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf')),
  size_bytes int not null check (size_bytes > 0 and size_bytes <= 20 * 1024 * 1024),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check (split_part(storage_path, '/', 1) = family_id::text),
  check (split_part(storage_path, '/', 2) = entity_type::text)
);

create index attachments_entity_idx on public.attachments (entity_type, entity_id);

-- Remove attachment rows when their parent transaction is deleted.
-- (Storage objects are garbage-collected by a scheduled job.)
create function private.delete_transaction_attachments() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.attachments where entity_type = 'transaction' and entity_id = old.id;
  return old;
end
$$;

create trigger transactions_delete_attachments after delete on public.transactions
for each row execute function private.delete_transaction_attachments();

alter table public.attachments enable row level security;

-- Visibility of an attachment == visibility of its parent (evaluated with the
-- caller's privileges, so the parent's RLS applies).
create policy attachments_select on public.attachments for select to authenticated
  using (
    case entity_type
      when 'transaction' then exists (
        select 1 from public.transactions t
        where t.id = attachments.entity_id and t.family_id = attachments.family_id
      )
      else false
    end
  );

create policy attachments_insert on public.attachments for insert to authenticated
  with check (
    created_by = auth.uid()
    and case entity_type
      when 'transaction' then exists (
        select 1 from public.transactions t
        where t.id = attachments.entity_id and t.family_id = attachments.family_id
      )
      else false
    end
  );

create policy attachments_delete on public.attachments for delete to authenticated
  using (
    (created_by = auth.uid() or private.has_role(family_id, 'admin'))
    and case entity_type
      when 'transaction' then exists (
        select 1 from public.transactions t
        where t.id = attachments.entity_id and t.family_id = attachments.family_id
      )
      else false
    end
  );

revoke all on public.attachments from anon, authenticated;
grant select, delete on public.attachments to authenticated;
grant insert (id, family_id, entity_type, entity_id, storage_path, mime_type, size_bytes)
  on public.attachments to authenticated;

revoke all on function private.delete_transaction_attachments() from public, anon, authenticated;
revoke all on function private.try_uuid(text) from public, anon;
grant execute on function private.try_uuid(text) to authenticated;

-- -----------------------------------------------------------------------------
-- storage.objects policies for the family-files bucket
-- -----------------------------------------------------------------------------
create policy family_files_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'family-files'
    and owner_id = auth.uid()::text
    and private.has_role(private.try_uuid((storage.foldername(name))[1]), 'adult')
  );

create policy family_files_select on storage.objects for select to authenticated
  using (
    bucket_id = 'family-files'
    and exists (select 1 from public.attachments a where a.storage_path = objects.name)
  );

-- The uploader may delete an object that is not yet linked (aborted upload);
-- linked objects follow the attachment's delete rule.
create policy family_files_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'family-files'
    and (
      (owner_id = auth.uid()::text
        and private.has_role(private.try_uuid((storage.foldername(name))[1]), 'adult')
        and not exists (select 1 from public.attachments a where a.storage_path = objects.name))
      or exists (
        select 1 from public.attachments a
        where a.storage_path = objects.name
          and (a.created_by = auth.uid() or private.has_role(a.family_id, 'admin'))
      )
    )
  );
