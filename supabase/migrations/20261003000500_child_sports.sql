-- =============================================================================
-- Children's sports calendar: weekly trainings (optionally until the season
-- ends) and one-off events (matches, competitions). The calendar itself is
-- expanded on the device (FamilyCore SportsCalendar); only the rules are stored.
-- Same access as the other child data: adults and admins.
-- =============================================================================

create type public.sport_entry_kind as enum ('training', 'event');

create table public.child_sports (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null,
  family_id uuid not null,
  kind public.sport_entry_kind not null,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  location text check (char_length(location) <= 160),
  notes text check (char_length(notes) <= 500),
  weekday smallint check (weekday between 1 and 7),  -- ISO, Monday = 1 (trainings)
  on_date date check (on_date between date '2000-01-01' and date '2100-01-01'),  -- events
  start_minute smallint not null check (start_minute between 0 and 1439),
  duration_minutes smallint not null default 60 check (duration_minutes between 5 and 720),
  until_date date check (until_date between date '2000-01-01' and date '2100-01-01'),  -- last training day
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (child_id, family_id) references public.children (id, family_id) on delete cascade,
  check (start_minute + duration_minutes <= 1440),
  check ((kind = 'training' and weekday is not null and on_date is null)
      or (kind = 'event' and on_date is not null and weekday is null and until_date is null))
);

create index child_sports_child_idx on public.child_sports (child_id);
create index child_sports_family_idx on public.child_sports (family_id);

alter table public.child_sports enable row level security;

create policy child_sports_select on public.child_sports for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy child_sports_insert on public.child_sports for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy child_sports_update on public.child_sports for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy child_sports_delete on public.child_sports for delete to authenticated
  using (private.has_role(family_id, 'adult'));

revoke all on public.child_sports from anon, authenticated;
grant select, delete on public.child_sports to authenticated;
grant insert (child_id, family_id, kind, title, location, notes, weekday, on_date, start_minute, duration_minutes, until_date)
  on public.child_sports to authenticated;
grant update (title, location, notes, weekday, on_date, start_minute, duration_minutes, until_date) on public.child_sports to authenticated;
