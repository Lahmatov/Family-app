-- =============================================================================
-- Children: profiles, vaccinations, growth measurements, illnesses.
--
-- Health data of minors: adults and admins of the family only (never child /
-- guest). Only admins can delete a child profile (cascades to all records).
-- The vaccination schedule itself is reference data kept in FamilyCore, not
-- in the database; here we store which doses were actually given.
-- =============================================================================

create type public.child_sex as enum ('female', 'male', 'unspecified');

create table public.children (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  birth_date date not null check (birth_date between date '2000-01-01' and current_date + 1),
  sex public.child_sex not null default 'unspecified',
  blood_type text check (blood_type in ('O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-')),
  allergies text check (char_length(allergies) <= 1000),
  notes text check (char_length(notes) <= 4000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, family_id)
);

create trigger children_updated_at before update on public.children
for each row execute function private.set_updated_at();

create table public.child_vaccinations (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null,
  family_id uuid not null,
  vaccine_code text not null check (vaccine_code ~ '^[a-z0-9_]{1,40}$'),
  dose smallint not null check (dose between 1 and 10),
  given_on date not null check (given_on between date '2000-01-01' and current_date + 1),
  batch text check (char_length(batch) <= 60),
  notes text check (char_length(notes) <= 1000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (child_id, family_id) references public.children (id, family_id) on delete cascade,
  unique (child_id, vaccine_code, dose)
);

create table public.child_measurements (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null,
  family_id uuid not null,
  measured_on date not null check (measured_on between date '2000-01-01' and current_date + 1),
  height_mm integer check (height_mm between 100 and 2500),
  weight_g integer check (weight_g between 300 and 300000),
  head_mm integer check (head_mm between 150 and 700),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check (height_mm is not null or weight_g is not null or head_mm is not null),
  foreign key (child_id, family_id) references public.children (id, family_id) on delete cascade,
  unique (child_id, measured_on)
);

create table public.child_illnesses (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null,
  family_id uuid not null,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  started_on date not null check (started_on between date '2000-01-01' and current_date + 1),
  ended_on date,
  notes text check (char_length(notes) <= 4000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check (ended_on is null or ended_on >= started_on),
  foreign key (child_id, family_id) references public.children (id, family_id) on delete cascade
);

create index child_vaccinations_child_idx on public.child_vaccinations (child_id);
create index child_measurements_child_idx on public.child_measurements (child_id, measured_on);
create index child_illnesses_child_idx on public.child_illnesses (child_id, started_on);

-- -----------------------------------------------------------------------------
-- RLS: identical rule for all four tables (adult+); deleting a child: admin only.
-- -----------------------------------------------------------------------------
alter table public.children enable row level security;
alter table public.child_vaccinations enable row level security;
alter table public.child_measurements enable row level security;
alter table public.child_illnesses enable row level security;

create policy children_select on public.children for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy children_insert on public.children for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy children_update on public.children for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy children_delete on public.children for delete to authenticated
  using (private.has_role(family_id, 'admin'));

do $$
declare
  t text;
begin
  foreach t in array array['child_vaccinations', 'child_measurements', 'child_illnesses'] loop
    execute format('create policy %I on public.%I for select to authenticated using (private.has_role(family_id, ''adult''))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.has_role(family_id, ''adult'') and created_by = auth.uid())', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.has_role(family_id, ''adult'')) with check (private.has_role(family_id, ''adult''))', t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using (private.has_role(family_id, ''adult''))', t || '_delete', t);
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on public.children, public.child_vaccinations, public.child_measurements, public.child_illnesses
  from anon, authenticated;

grant select, delete on public.children, public.child_vaccinations,
  public.child_measurements, public.child_illnesses to authenticated;

grant insert (family_id, name, birth_date, sex, blood_type, allergies, notes) on public.children to authenticated;
grant update (name, birth_date, sex, blood_type, allergies, notes) on public.children to authenticated;

grant insert (child_id, family_id, vaccine_code, dose, given_on, batch, notes) on public.child_vaccinations to authenticated;
grant update (given_on, batch, notes) on public.child_vaccinations to authenticated;

grant insert (child_id, family_id, measured_on, height_mm, weight_g, head_mm) on public.child_measurements to authenticated;
grant update (measured_on, height_mm, weight_g, head_mm) on public.child_measurements to authenticated;

grant insert (child_id, family_id, title, started_on, ended_on, notes) on public.child_illnesses to authenticated;
grant update (title, started_on, ended_on, notes) on public.child_illnesses to authenticated;
