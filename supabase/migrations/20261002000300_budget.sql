-- =============================================================================
-- Budget: categories, transactions (expenses / income), monthly budgets.
--
-- Money is stored as integer minor units (cents) + ISO-4217 code. Each
-- transaction also stores its value in the family's base currency, computed
-- SERVER-SIDE from the client-supplied FX rate, so totals are never
-- inconsistent with the stored rate.
--
-- Access: finance is visible to admins and adults only. A transaction marked
-- private is visible to its author only.
-- =============================================================================

create type public.txn_kind as enum ('expense', 'income');

-- Minor unit exponent per ISO 4217 (default 2). Mirrors FamilyCore.CurrencyCode.
create function private.currency_exponent(p_currency text) returns int
language sql immutable
set search_path = ''
as $$
  select case
    when p_currency in ('BIF','CLP','DJF','GNF','ISK','JPY','KMF','KRW','PYG','RWF','UGX','UYI','VND','VUV','XAF','XOF','XPF') then 0
    when p_currency in ('BHD','IQD','JOD','KWD','LYD','OMR','TND') then 3
    else 2
  end
$$;

-- -----------------------------------------------------------------------------
-- Categories
-- -----------------------------------------------------------------------------
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.txn_kind not null,
  -- Built-in categories carry a key that the app localises; custom ones a name.
  system_key text check (system_key ~ '^[a-z_]{1,40}$'),
  name text check (char_length(btrim(name)) between 1 and 60),
  icon text check (icon ~ '^[a-z0-9.]{1,64}$'),
  color text check (color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order int not null default 0,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  check (system_key is not null or name is not null),
  unique (family_id, kind, system_key),
  unique (id, family_id, kind)
);

create function private.seed_default_categories() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.categories (family_id, kind, system_key, icon, color, sort_order)
  select new.id, c.kind::public.txn_kind, c.key, c.icon, c.color, c.ord
  from (values
    ('expense', 'groceries',     'cart',                    '#34C759', 10),
    ('expense', 'housing',       'house',                   '#007AFF', 20),
    ('expense', 'utilities',     'bolt',                    '#FFCC00', 30),
    ('expense', 'transport',     'car',                     '#5856D6', 40),
    ('expense', 'kids',          'figure.and.child.holdinghands', '#FF9500', 50),
    ('expense', 'health',        'cross.case',              '#FF3B30', 60),
    ('expense', 'education',     'book',                    '#AF52DE', 70),
    ('expense', 'sport',         'figure.run',              '#30B0C7', 80),
    ('expense', 'restaurants',   'fork.knife',              '#FF2D55', 90),
    ('expense', 'shopping',      'bag',                     '#A2845E', 100),
    ('expense', 'travel',        'airplane',                '#32ADE6', 110),
    ('expense', 'subscriptions', 'repeat',                  '#8E8E93', 120),
    ('expense', 'loans',         'banknote',                '#636366', 130),
    ('expense', 'gifts',         'gift',                    '#FF6482', 140),
    ('expense', 'other',         'ellipsis.circle',         '#AEAEB2', 1000),
    ('income',  'salary',        'briefcase',               '#34C759', 10),
    ('income',  'benefits',      'building.columns',        '#007AFF', 20),
    ('income',  'other_income',  'plus.circle',             '#AEAEB2', 1000)
  ) as c(kind, key, icon, color, ord);
  return new;
end
$$;

create trigger families_seed_categories after insert on public.families
for each row execute function private.seed_default_categories();

-- -----------------------------------------------------------------------------
-- Transactions
-- -----------------------------------------------------------------------------
create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  kind public.txn_kind not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor < 100000000000),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  -- units of base currency per 1 unit of `currency`
  fx_rate numeric(20, 10) not null default 1 check (fx_rate > 0 and fx_rate < 1000000),
  amount_base_minor bigint not null default 0,
  category_id uuid not null,
  occurred_on date not null default current_date
    check (occurred_on between date '2000-01-01' and date '2100-01-01'),
  merchant text check (char_length(merchant) <= 120),
  note text check (char_length(note) <= 2000),
  paid_by uuid references auth.users (id) on delete set null,
  is_private boolean not null default false,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- category must belong to the same family and be of the same kind
  foreign key (category_id, family_id, kind)
    references public.categories (id, family_id, kind) on delete restrict
);

create index transactions_family_date_idx on public.transactions (family_id, occurred_on desc);
create index transactions_category_idx on public.transactions (category_id);

create function private.transactions_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_base text;
  v_shift int;
begin
  if tg_op = 'UPDATE' then
    -- Immutable columns, regardless of column grants.
    new.family_id := old.family_id;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;

  select base_currency into v_base from public.families where id = new.family_id;

  if new.currency = v_base then
    new.fx_rate := 1;
  end if;

  v_shift := private.currency_exponent(v_base) - private.currency_exponent(new.currency);
  new.amount_base_minor := round(new.amount_minor * new.fx_rate * power(10::numeric, v_shift))::bigint;
  if new.amount_minor > 0 and new.amount_base_minor <= 0 then
    raise exception 'amount too small after conversion' using errcode = '22003';
  end if;

  if new.paid_by is not null and not private.is_member(new.family_id, new.paid_by) then
    raise exception 'paid_by must be a family member' using errcode = '23503';
  end if;

  new.updated_at := now();
  return new;
end
$$;

create trigger transactions_before_write before insert or update on public.transactions
for each row execute function private.transactions_before_write();

-- -----------------------------------------------------------------------------
-- Budgets: monthly limit per category (or overall when category_id is null),
-- in base currency. A row applies from `valid_from` until a newer row exists.
-- -----------------------------------------------------------------------------
create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  category_id uuid,
  kind public.txn_kind not null default 'expense' check (kind = 'expense'),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor < 100000000000),
  valid_from date not null check (extract(day from valid_from) = 1),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (category_id, family_id, kind)
    references public.categories (id, family_id, kind) on delete cascade,
  unique nulls not distinct (family_id, category_id, valid_from)
);

create trigger budgets_updated_at before update on public.budgets
for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Report: spent vs budget per category for a month, plus one overall row
-- (category_id NULL). SECURITY INVOKER, so RLS
-- applies (private transactions of others are not counted for the caller).
-- -----------------------------------------------------------------------------
create function public.budget_report(p_family uuid, p_month date)
returns table (category_id uuid, budget_minor bigint, spent_minor bigint)
language sql stable security invoker
set search_path = ''
as $$
  with bounds as (
    select date_trunc('month', p_month)::date as m_start,
           (date_trunc('month', p_month) + interval '1 month')::date as m_end
  ),
  spent as (
    select t.category_id, sum(t.amount_base_minor)::bigint as spent_minor
    from public.transactions t, bounds b
    where t.family_id = p_family and t.kind = 'expense'
      and t.occurred_on >= b.m_start and t.occurred_on < b.m_end
    group by t.category_id
  ),
  current_budgets as (
    select distinct on (bu.category_id) bu.category_id, bu.amount_minor
    from public.budgets bu, bounds b
    where bu.family_id = p_family and bu.valid_from <= b.m_start
    order by bu.category_id, bu.valid_from desc
  ),
  per_category as (
    select coalesce(cb.category_id, s.category_id) as category_id,
           cb.amount_minor as budget_minor,
           coalesce(s.spent_minor, 0)::bigint as spent_minor
    from (select * from current_budgets where category_id is not null) cb
    full join spent s on s.category_id = cb.category_id
  )
  select category_id, budget_minor, spent_minor from per_category
  union all
  -- overall line: category_id NULL, always present
  select null::uuid,
         (select amount_minor from current_budgets where category_id is null),
         coalesce((select sum(spent_minor) from spent), 0)::bigint
$$;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.categories enable row level security;
alter table public.transactions enable row level security;
alter table public.budgets enable row level security;

create policy categories_select on public.categories for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy categories_insert on public.categories for insert to authenticated
  with check (private.has_role(family_id, 'adult') and system_key is null);
create policy categories_update on public.categories for update to authenticated
  using (private.has_role(family_id, 'adult'))
  with check (private.has_role(family_id, 'adult'));
create policy categories_delete on public.categories for delete to authenticated
  using (private.has_role(family_id, 'admin') and system_key is null);

create policy transactions_select on public.transactions for select to authenticated
  using (private.has_role(family_id, 'adult') and (not is_private or created_by = auth.uid()));
create policy transactions_insert on public.transactions for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy transactions_update on public.transactions for update to authenticated
  using (
    private.has_role(family_id, 'adult')
    and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private))
  )
  with check (
    private.has_role(family_id, 'adult')
    and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private))
  );
create policy transactions_delete on public.transactions for delete to authenticated
  using (
    private.has_role(family_id, 'adult')
    and (created_by = auth.uid() or (private.has_role(family_id, 'admin') and not is_private))
  );

create policy budgets_select on public.budgets for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy budgets_insert on public.budgets for insert to authenticated
  with check (private.has_role(family_id, 'admin'));
create policy budgets_update on public.budgets for update to authenticated
  using (private.has_role(family_id, 'admin')) with check (private.has_role(family_id, 'admin'));
create policy budgets_delete on public.budgets for delete to authenticated
  using (private.has_role(family_id, 'admin'));

-- -----------------------------------------------------------------------------
-- Privileges
-- -----------------------------------------------------------------------------
revoke all on public.categories, public.transactions, public.budgets from anon, authenticated;

grant select, delete on public.categories to authenticated;
grant insert (family_id, kind, name, icon, color, sort_order) on public.categories to authenticated;
grant update (name, icon, color, sort_order, archived) on public.categories to authenticated;

grant select, delete on public.transactions to authenticated;
grant insert (id, family_id, kind, amount_minor, currency, fx_rate, category_id, occurred_on,
              merchant, note, paid_by, is_private) on public.transactions to authenticated;
grant update (kind, amount_minor, currency, fx_rate, category_id, occurred_on,
              merchant, note, paid_by, is_private) on public.transactions to authenticated;

grant select, delete on public.budgets to authenticated;
grant insert (family_id, category_id, amount_minor, valid_from) on public.budgets to authenticated;
grant update (amount_minor) on public.budgets to authenticated;

revoke all on function private.currency_exponent(text) from public, anon, authenticated;
revoke all on function private.seed_default_categories() from public, anon, authenticated;
revoke all on function private.transactions_before_write() from public, anon, authenticated;

revoke all on function public.budget_report(uuid, date) from public, anon;
grant execute on function public.budget_report(uuid, date) to authenticated;
