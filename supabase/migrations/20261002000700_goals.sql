-- =============================================================================
-- Goals: save money, lose weight, pass an exam. A goal has a start value, a
-- target value (which may be lower than the start, e.g. weight loss), an
-- optional deadline and dated progress entries.
--
-- Access: adults and admins. A private goal (e.g. a personal weight goal) is
-- visible only to its author, admins included. Entries inherit the goal's
-- visibility through RLS on the parent.
-- =============================================================================

create type public.goal_kind as enum ('savings', 'weight', 'other');

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.goal_kind not null default 'other',
  title text not null check (char_length(btrim(title)) between 1 and 120),
  unit text not null default '' check (char_length(unit) <= 12),
  start_value numeric(14, 3) not null check (abs(start_value) < 1e11),
  target_value numeric(14, 3) not null check (abs(target_value) < 1e11),
  starts_on date not null default current_date check (starts_on between date '2000-01-01' and date '2100-01-01'),
  deadline date check (deadline between date '2000-01-01' and date '2100-01-01'),
  is_private boolean not null default false,
  achieved_on date,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (target_value <> start_value),
  check (deadline is null or deadline >= starts_on),
  unique (id, family_id)
);

create trigger goals_updated_at before update on public.goals
for each row execute function private.set_updated_at();

create table public.goal_entries (
  id uuid primary key default gen_random_uuid(),
  goal_id uuid not null,
  family_id uuid not null,
  value numeric(14, 3) not null check (abs(value) < 1e11),
  recorded_on date not null default current_date check (recorded_on between date '2000-01-01' and date '2100-01-01'),
  note text check (char_length(note) <= 500),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (goal_id, family_id) references public.goals (id, family_id) on delete cascade,
  unique (goal_id, recorded_on)
);

create index goals_family_idx on public.goals (family_id);
create index goal_entries_goal_idx on public.goal_entries (goal_id, recorded_on);

alter table public.goals enable row level security;
alter table public.goal_entries enable row level security;

create policy goals_select on public.goals for select to authenticated
  using (private.has_role(family_id, 'adult') and (not is_private or created_by = auth.uid()));
create policy goals_insert on public.goals for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy goals_update on public.goals for update to authenticated
  using (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)))
  with check (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)));
create policy goals_delete on public.goals for delete to authenticated
  using (private.has_role(family_id, 'adult')
         and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private)));

-- Entries: visible/writable exactly when the parent goal is visible (its RLS applies
-- inside the subquery); family members may log progress on shared goals.
create policy goal_entries_select on public.goal_entries for select to authenticated
  using (exists (select 1 from public.goals g where g.id = goal_entries.goal_id and g.family_id = goal_entries.family_id));
create policy goal_entries_insert on public.goal_entries for insert to authenticated
  with check (created_by = auth.uid()
    and exists (select 1 from public.goals g where g.id = goal_entries.goal_id and g.family_id = goal_entries.family_id));
create policy goal_entries_update on public.goal_entries for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy goal_entries_delete on public.goal_entries for delete to authenticated
  using (created_by = auth.uid()
    or exists (select 1 from public.goals g where g.id = goal_entries.goal_id and g.created_by = auth.uid()));

revoke all on public.goals, public.goal_entries from anon, authenticated;
grant select, delete on public.goals, public.goal_entries to authenticated;
grant insert (family_id, kind, title, unit, start_value, target_value, starts_on, deadline, is_private)
  on public.goals to authenticated;
grant update (title, unit, target_value, deadline, is_private, achieved_on) on public.goals to authenticated;
grant insert (goal_id, family_id, value, recorded_on, note) on public.goal_entries to authenticated;
grant update (value, note) on public.goal_entries to authenticated;
