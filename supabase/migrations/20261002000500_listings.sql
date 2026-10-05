-- =============================================================================
-- Apartment hunting: listings, family criteria (checklist with weights),
-- per-listing answers, comments.
--
-- Access: adults and admins of the family. Everyone with access can edit
-- (it is a shared workspace); only the author or an admin can delete.
-- =============================================================================

create type public.listing_status as enum ('new', 'to_visit', 'visited', 'shortlisted', 'rejected');
create type public.criterion_answer as enum ('yes', 'no', 'unknown');

create table public.listings (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  url text not null check (url ~ '^https://[^\s]+$' and char_length(url) <= 2048),
  source text check (char_length(source) <= 40),
  title text not null default '' check (char_length(title) <= 200),
  price_minor bigint check (price_minor > 0 and price_minor < 100000000000),
  currency char(3) not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  area_m2 numeric(8, 2) check (area_m2 > 0 and area_m2 < 100000),
  rooms smallint check (rooms between 0 and 50),
  floor smallint check (floor between -5 and 200),
  address text check (char_length(address) <= 300),
  lat double precision check (lat between -90 and 90),
  lng double precision check (lng between -180 and 180),
  status public.listing_status not null default 'new',
  visited_on date,
  notes text check (char_length(notes) <= 4000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((lat is null) = (lng is null)),
  unique (family_id, url),
  unique (id, family_id)
);

create index listings_family_idx on public.listings (family_id, status);

create trigger listings_updated_at before update on public.listings
for each row execute function private.set_updated_at();

-- What the family cares about ("balcony", "metro < 10 min"); weight 1..5.
create table public.listing_criteria (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  weight smallint not null default 3 check (weight between 1 and 5),
  created_at timestamptz not null default now(),
  unique (family_id, name),
  unique (id, family_id)
);

create table public.listing_answers (
  listing_id uuid not null,
  criterion_id uuid not null,
  family_id uuid not null,
  answer public.criterion_answer not null default 'unknown',
  primary key (listing_id, criterion_id),
  foreign key (listing_id, family_id) references public.listings (id, family_id) on delete cascade,
  foreign key (criterion_id, family_id) references public.listing_criteria (id, family_id) on delete cascade
);

create table public.listing_comments (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null,
  family_id uuid not null,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (listing_id, family_id) references public.listings (id, family_id) on delete cascade
);

create index listing_comments_idx on public.listing_comments (listing_id, created_at);

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.listings enable row level security;
alter table public.listing_criteria enable row level security;
alter table public.listing_answers enable row level security;
alter table public.listing_comments enable row level security;

create policy listings_select on public.listings for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy listings_insert on public.listings for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy listings_update on public.listings for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy listings_delete on public.listings for delete to authenticated
  using (private.has_role(family_id, 'adult') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

create policy criteria_select on public.listing_criteria for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy criteria_insert on public.listing_criteria for insert to authenticated
  with check (private.has_role(family_id, 'adult'));
create policy criteria_update on public.listing_criteria for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy criteria_delete on public.listing_criteria for delete to authenticated
  using (private.has_role(family_id, 'adult'));

create policy answers_select on public.listing_answers for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy answers_insert on public.listing_answers for insert to authenticated
  with check (private.has_role(family_id, 'adult'));
create policy answers_update on public.listing_answers for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy answers_delete on public.listing_answers for delete to authenticated
  using (private.has_role(family_id, 'adult'));

create policy comments_select on public.listing_comments for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy comments_insert on public.listing_comments for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy comments_delete on public.listing_comments for delete to authenticated
  using (private.has_role(family_id, 'adult') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on public.listings, public.listing_criteria, public.listing_answers, public.listing_comments
  from anon, authenticated;

grant select, delete on public.listings to authenticated;
grant insert (id, family_id, url, source, title, price_minor, currency, area_m2, rooms, floor, address,
              lat, lng, status, visited_on, notes) on public.listings to authenticated;
grant update (url, source, title, price_minor, currency, area_m2, rooms, floor, address,
              lat, lng, status, visited_on, notes) on public.listings to authenticated;

grant select, delete on public.listing_criteria to authenticated;
grant insert (family_id, name, weight) on public.listing_criteria to authenticated;
grant update (name, weight) on public.listing_criteria to authenticated;

grant select, delete on public.listing_answers to authenticated;
grant insert (listing_id, criterion_id, family_id, answer) on public.listing_answers to authenticated;
grant update (answer) on public.listing_answers to authenticated;

grant select, delete on public.listing_comments to authenticated;
grant insert (listing_id, family_id, body) on public.listing_comments to authenticated;
