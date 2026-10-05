-- =============================================================================
-- Vacation planning: a trip has dates, a budget and a list of items (transport,
-- stay, activities, to-dos) with optional day, cost and a done flag.
-- Costs are money, so access is adults and admins, like loans and budget.
-- Everything is in the trip's currency; no FX inside a trip.
-- =============================================================================

create type public.trip_item_kind as enum ('transport', 'stay', 'activity', 'todo');

create table public.trips (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  destination text not null default '' check (char_length(destination) <= 120),
  starts_on date not null check (starts_on between date '2000-01-01' and date '2100-01-01'),
  ends_on date not null check (ends_on between date '2000-01-01' and date '2100-01-01'),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  budget_minor bigint not null default 0 check (budget_minor between 0 and 100000000000),
  notes text check (char_length(notes) <= 2000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (ends_on - starts_on <= 366),
  unique (id, family_id)
);

create trigger trips_updated_at before update on public.trips
for each row execute function private.set_updated_at();

create table public.trip_items (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null,
  family_id uuid not null,
  kind public.trip_item_kind not null default 'todo',
  title text not null check (char_length(btrim(title)) between 1 and 160),
  day date check (day between date '2000-01-01' and date '2100-01-01'),
  cost_minor bigint not null default 0 check (cost_minor between 0 and 100000000000),
  is_done boolean not null default false,
  link text check (link is null or (char_length(link) <= 500 and link ~* '^https://[^\s]+$')),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (trip_id, family_id) references public.trips (id, family_id) on delete cascade
);

create index trips_family_idx on public.trips (family_id, starts_on);
create index trip_items_trip_idx on public.trip_items (trip_id);

alter table public.trips enable row level security;
alter table public.trip_items enable row level security;

create policy trips_select on public.trips for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy trips_insert on public.trips for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy trips_update on public.trips for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy trips_delete on public.trips for delete to authenticated
  using (private.has_role(family_id, 'adult') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

create policy trip_items_select on public.trip_items for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy trip_items_insert on public.trip_items for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy trip_items_update on public.trip_items for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy trip_items_delete on public.trip_items for delete to authenticated
  using (private.has_role(family_id, 'adult'));

revoke all on public.trips, public.trip_items from anon, authenticated;
grant select, delete on public.trips, public.trip_items to authenticated;
grant insert (family_id, title, destination, starts_on, ends_on, currency, budget_minor, notes) on public.trips to authenticated;
grant update (title, destination, starts_on, ends_on, budget_minor, notes) on public.trips to authenticated;
grant insert (trip_id, family_id, kind, title, day, cost_minor, link) on public.trip_items to authenticated;
grant update (title, day, cost_minor, is_done, link) on public.trip_items to authenticated;
