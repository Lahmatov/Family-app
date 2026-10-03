-- =============================================================================
-- Loans: terms are immutable after creation (no rewriting history); everything that
-- changes over time is a separate dated row: rate changes (variable rate, e.g. Euribor),
-- extra payments, and the installments that were actually paid.
-- The payment schedule itself is computed on the device (FamilyCore.LoanCalculator).
--
-- Access: adults and admins (family finances). Deleting a loan: its author or an admin.
-- =============================================================================

create type public.loan_type as enum ('annuity', 'differentiated');
create type public.extra_strategy as enum ('reduce_term', 'reduce_payment');

create table public.loans (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  lender text check (char_length(lender) <= 120),
  principal_minor bigint not null check (principal_minor > 0 and principal_minor < 100000000000),
  currency char(3) not null check (currency ~ '^[A-Z]{3}$'),
  annual_rate numeric(7, 4) not null check (annual_rate >= 0 and annual_rate <= 100),
  term_months int not null check (term_months between 1 and 600),
  first_payment_on date not null check (first_payment_on between date '2000-01-01' and date '2100-01-01'),
  loan_type public.loan_type not null default 'annuity',
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, family_id)
);

create trigger loans_updated_at before update on public.loans
for each row execute function private.set_updated_at();

create table public.loan_rate_changes (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null,
  family_id uuid not null,
  effective_from date not null check (effective_from between date '2000-01-01' and date '2100-01-01'),
  annual_rate numeric(7, 4) not null check (annual_rate >= 0 and annual_rate <= 100),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (loan_id, family_id) references public.loans (id, family_id) on delete cascade,
  unique (loan_id, effective_from)
);

create table public.loan_extra_payments (
  id uuid primary key default gen_random_uuid(),
  loan_id uuid not null,
  family_id uuid not null,
  paid_on date not null check (paid_on between date '2000-01-01' and date '2100-01-01'),
  amount_minor bigint not null check (amount_minor > 0 and amount_minor < 100000000000),
  strategy public.extra_strategy not null default 'reduce_term',
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (loan_id, family_id) references public.loans (id, family_id) on delete cascade
);

create table public.loan_payments (
  loan_id uuid not null,
  family_id uuid not null,
  installment_no int not null check (installment_no between 1 and 600),
  paid_on date not null check (paid_on between date '2000-01-01' and date '2100-01-01'),
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (loan_id, installment_no),
  foreign key (loan_id, family_id) references public.loans (id, family_id) on delete cascade
);

create index loans_family_idx on public.loans (family_id);
create index loan_rate_changes_loan_idx on public.loan_rate_changes (loan_id, effective_from);
create index loan_extra_payments_loan_idx on public.loan_extra_payments (loan_id, paid_on);

alter table public.loans enable row level security;
alter table public.loan_rate_changes enable row level security;
alter table public.loan_extra_payments enable row level security;
alter table public.loan_payments enable row level security;

create policy loans_select on public.loans for select to authenticated
  using (private.has_role(family_id, 'adult'));
create policy loans_insert on public.loans for insert to authenticated
  with check (private.has_role(family_id, 'adult') and created_by = auth.uid());
create policy loans_update on public.loans for update to authenticated
  using (private.has_role(family_id, 'adult')) with check (private.has_role(family_id, 'adult'));
create policy loans_delete on public.loans for delete to authenticated
  using (private.has_role(family_id, 'adult') and (created_by = auth.uid() or private.has_role(family_id, 'admin')));

do $$
declare
  t text;
begin
  foreach t in array array['loan_rate_changes', 'loan_extra_payments', 'loan_payments'] loop
    execute format('create policy %I on public.%I for select to authenticated using (private.has_role(family_id, ''adult''))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.has_role(family_id, ''adult'') and created_by = auth.uid())', t || '_insert', t);
    execute format('create policy %I on public.%I for delete to authenticated using (private.has_role(family_id, ''adult''))', t || '_delete', t);
  end loop;
end
$$;

revoke all on public.loans, public.loan_rate_changes, public.loan_extra_payments, public.loan_payments
  from anon, authenticated;
grant select, delete on public.loans, public.loan_rate_changes, public.loan_extra_payments, public.loan_payments
  to authenticated;
grant insert (family_id, title, lender, principal_minor, currency, annual_rate, term_months, first_payment_on, loan_type)
  on public.loans to authenticated;
grant update (title, lender) on public.loans to authenticated;
grant insert (loan_id, family_id, effective_from, annual_rate) on public.loan_rate_changes to authenticated;
grant insert (loan_id, family_id, paid_on, amount_minor, strategy) on public.loan_extra_payments to authenticated;
grant insert (loan_id, family_id, installment_no, paid_on) on public.loan_payments to authenticated;
