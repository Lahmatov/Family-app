-- =============================================================================
-- Family tasks with a discussion thread per task ("renew passports", "book the
-- dentist"). Everyone in the family except guests can see and work on them,
-- children included (chores); only the author or an admin can delete.
-- The assignee must be a member of the same family; when that person leaves,
-- the task simply becomes unassigned.
-- =============================================================================

create type public.task_status as enum ('todo', 'doing', 'done');

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 160),
  description text check (char_length(description) <= 2000),
  status public.task_status not null default 'todo',
  assignee_id uuid,
  due_on date check (due_on between date '2000-01-01' and date '2100-01-01'),
  done_at timestamptz,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, family_id),
  foreign key (family_id, assignee_id) references public.family_members (family_id, user_id) on delete set null (assignee_id)
);

create trigger tasks_updated_at before update on public.tasks
for each row execute function private.set_updated_at();

create function private.tasks_done_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then
    new.done_at := now();
  elsif new.status <> 'done' then
    new.done_at := null;
  end if;
  return new;
end
$$;

create trigger tasks_done_at before insert or update of status on public.tasks
for each row execute function private.tasks_done_at();

create table public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null,
  family_id uuid not null,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (task_id, family_id) references public.tasks (id, family_id) on delete cascade
);

create index tasks_family_idx on public.tasks (family_id, status);
create index task_comments_task_idx on public.task_comments (task_id, created_at);

alter table public.tasks enable row level security;
alter table public.task_comments enable row level security;

create policy tasks_select on public.tasks for select to authenticated
  using (private.has_role(family_id, 'child'));
create policy tasks_insert on public.tasks for insert to authenticated
  with check (private.has_role(family_id, 'child') and created_by = auth.uid());
create policy tasks_update on public.tasks for update to authenticated
  using (private.has_role(family_id, 'child')) with check (private.has_role(family_id, 'child'));
create policy tasks_delete on public.tasks for delete to authenticated
  using (private.has_role(family_id, 'child') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

create policy task_comments_select on public.task_comments for select to authenticated
  using (private.has_role(family_id, 'child'));
create policy task_comments_insert on public.task_comments for insert to authenticated
  with check (private.has_role(family_id, 'child') and created_by = auth.uid());
create policy task_comments_delete on public.task_comments for delete to authenticated
  using (private.has_role(family_id, 'child') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

revoke all on public.tasks, public.task_comments from anon, authenticated;
revoke all on function private.tasks_done_at() from public, anon, authenticated;
grant select, delete on public.tasks, public.task_comments to authenticated;
grant insert (family_id, title, description, status, assignee_id, due_on) on public.tasks to authenticated;
grant update (title, description, status, assignee_id, due_on) on public.tasks to authenticated;
grant insert (task_id, family_id, body) on public.task_comments to authenticated;
