-- =============================================================================
-- Notes: shared family notes and private notes (author only, admins included).
-- Privacy of a note is fixed at creation: flipping it later would let a
-- non-author hide or expose someone else's text, so is_private is immutable.
-- =============================================================================

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  title text not null default '' check (char_length(title) <= 120),
  body text not null default '' check (char_length(body) <= 20000),
  is_private boolean not null default false,
  pinned boolean not null default false,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (btrim(title) <> '' or btrim(body) <> '')
);

create index notes_family_idx on public.notes (family_id, updated_at desc);

create trigger notes_updated_at before update on public.notes
for each row execute function private.set_updated_at();

alter table public.notes enable row level security;

create policy notes_select on public.notes for select to authenticated
  using (private.has_role(family_id, 'adult') and (not is_private or created_by = auth.uid()));
create policy notes_insert on public.notes for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy notes_update on public.notes for update to authenticated
  using (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)))
  with check (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)));
create policy notes_delete on public.notes for delete to authenticated
  using (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)));

revoke all on public.notes from anon, authenticated;
grant select, delete on public.notes to authenticated;
grant insert (family_id, title, body, is_private, pinned) on public.notes to authenticated;
grant update (title, body, pinned) on public.notes to authenticated;
