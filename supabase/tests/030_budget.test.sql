-- Transactions, categories, budgets: access rules, server-side FX, tamper resistance.
begin;
select plan(34);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('kid',   tests.create_user('kid@example.com'));    -- child
select tests.set_id('gran',  tests.create_user('gran@example.com'));   -- guest
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family admin

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('kid'), 'child');
select tests.add_member(tests.id('fam'), tests.id('gran'), 'guest');

select tests.set_id('groceries', tests.category(tests.id('fam'), 'groceries'));
select tests.set_id('salary', tests.category(tests.id('fam'), 'salary'));
select tests.set_id('eve_groceries', tests.category(tests.id('evefam'), 'groceries'));

-- ---- inserting & FX -----------------------------------------------------------
select tests.login(tests.id('bob'));
select tests.set_id('t1', gen_random_uuid());
select lives_ok($$
  insert into public.transactions (id, family_id, kind, amount_minor, currency, category_id, occurred_on, paid_by)
  values (tests.id('t1'), tests.id('fam'), 'expense', 4550, 'EUR', tests.id('groceries'), '2026-10-01', tests.id('alice'))
$$, 'adult adds an expense');
select is((select amount_base_minor from public.transactions where id = tests.id('t1')), 4550::bigint,
  'base amount equals amount in base currency');
select is((select created_by from public.transactions where id = tests.id('t1')), tests.id('bob'),
  'created_by is set from the session');

select tests.set_id('t2', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, fx_rate, category_id, occurred_on)
values (tests.id('t2'), tests.id('fam'), 'expense', 1000, 'USD', 0.9, tests.id('groceries'), '2026-10-02');
select is((select amount_base_minor from public.transactions where id = tests.id('t2')), 900::bigint,
  'USD converted with the given rate');

select tests.set_id('t3', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, fx_rate, category_id, occurred_on)
values (tests.id('t3'), tests.id('fam'), 'expense', 1000, 'JPY', 0.0062, tests.id('groceries'), '2026-10-03');
select is((select amount_base_minor from public.transactions where id = tests.id('t3')), 620::bigint,
  'zero-decimal currency (JPY) converted with exponent shift');

select tests.set_id('t4', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, fx_rate, category_id, occurred_on)
values (tests.id('t4'), tests.id('fam'), 'expense', 100, 'EUR', 5, tests.id('groceries'), '2026-10-04');
select is((select (fx_rate, amount_base_minor)::text from public.transactions where id = tests.id('t4')),
  '(1.0000000000,100)', 'fx_rate forced to 1 for base currency (no inflated totals)');

-- ---- tampering --------------------------------------------------------------
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id, created_by)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('groceries'), tests.id('alice'))
$$, '42501', null, 'cannot spoof created_by');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id, amount_base_minor)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('groceries'), 999999)
$$, '42501', null, 'cannot set amount_base_minor directly');
select throws_ok($$
  update public.transactions set family_id = tests.id('evefam') where id = tests.id('t1')
$$, '42501', null, 'cannot move a transaction to another family');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('eve_groceries'))
$$, '23503', null, 'cannot use another family''s category');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('salary'))
$$, '23503', null, 'category kind must match transaction kind');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id, paid_by)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('groceries'), tests.id('eve'))
$$, '23503', null, 'paid_by must be a family member');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id)
  values (tests.id('fam'), 'expense', -100, 'EUR', tests.id('groceries'))
$$, '23514', null, 'negative amounts rejected');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id)
  values (tests.id('evefam'), 'expense', 100, 'EUR', tests.id('eve_groceries'))
$$, '42501', null, 'cannot insert into another family');

-- ---- visibility by role ------------------------------------------------------
select tests.login(tests.id('kid'));
select is((select count(*)::int from public.transactions), 0, 'child sees no finance');
select throws_ok($$
  insert into public.transactions (family_id, kind, amount_minor, currency, category_id)
  values (tests.id('fam'), 'expense', 100, 'EUR', tests.id('groceries'))
$$, '42501', null, 'child cannot add expenses');

select tests.login(tests.id('gran'));
select is((select count(*)::int from public.transactions), 0, 'guest sees no finance');
select is((select count(*)::int from public.categories), 0, 'guest sees no categories');

select tests.login(tests.id('eve'));
select is((select count(*)::int from public.transactions where family_id = tests.id('fam')), 0,
  'other family sees nothing');
delete from public.transactions where id = tests.id('t1');

select tests.login(tests.id('alice'), 'aal1');
select is((select count(*)::int from public.transactions), 0, 'no finance without MFA');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.transactions), 4, 'admin sees family transactions');

-- ---- private transactions ---------------------------------------------------------
select tests.login(tests.id('bob'));
select tests.set_id('tp', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, category_id, occurred_on, is_private)
values (tests.id('tp'), tests.id('fam'), 'expense', 7000, 'EUR', tests.id('groceries'), '2026-10-05', true);
select is((select count(*)::int from public.transactions where id = tests.id('tp')), 1, 'author sees own private expense');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.transactions where id = tests.id('tp')), 0, 'admin cannot see others private expense');
update public.transactions set amount_minor = 1 where id = tests.id('tp');
delete from public.transactions where id = tests.id('tp');

-- ---- edit rules --------------------------------------------------------------------
update public.transactions set note = 'checked by admin' where id = tests.id('t1');

select tests.set_id('ta', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, category_id, occurred_on)
values (tests.id('ta'), tests.id('fam'), 'expense', 500, 'EUR', tests.id('groceries'), '2026-10-06');

select tests.login(tests.id('bob'));
update public.transactions set amount_minor = 1 where id = tests.id('ta');
delete from public.transactions where id = tests.id('ta');

select tests.logout();
select is((select amount_minor from public.transactions where id = tests.id('tp')), 7000::bigint,
  'admin cannot modify others private expense');
select is((select note from public.transactions where id = tests.id('t1')), 'checked by admin',
  'admin can edit a shared expense of another member');
select is((select amount_minor from public.transactions where id = tests.id('ta')), 500::bigint,
  'adult cannot edit someone else''s expense');

-- ---- budgets & report -------------------------------------------------------------
select tests.login(tests.id('bob'));
select throws_ok($$
  insert into public.budgets (family_id, category_id, amount_minor, valid_from)
  values (tests.id('fam'), tests.id('groceries'), 50000, '2026-10-01')
$$, '42501', null, 'adult cannot set budgets');

select tests.login(tests.id('alice'));
select lives_ok($$
  insert into public.budgets (family_id, category_id, amount_minor, valid_from) values
    (tests.id('fam'), tests.id('groceries'), 50000, '2026-09-01'),
    (tests.id('fam'), null, 300000, '2026-01-01')
$$, 'admin sets category and overall budgets');
select throws_ok($$
  insert into public.budgets (family_id, category_id, amount_minor, valid_from)
  values (tests.id('fam'), tests.id('salary'), 1000, '2026-10-01')
$$, '23503', null, 'budgets only for expense categories');
select throws_ok($$
  insert into public.budgets (family_id, category_id, amount_minor, valid_from)
  values (tests.id('fam'), tests.id('groceries'), 1000, '2026-10-15')
$$, '23514', null, 'budget must start on the first day of a month');

-- t1 4550 + t2 900 + t3 620 + t4 100 + ta 500 = 6670 visible to Alice
select results_eq(
  $$ select category_id, budget_minor, spent_minor from public.budget_report(tests.id('fam'), '2026-10-20') order by category_id nulls last $$,
  $$ values (tests.id('groceries'), 50000::bigint, 6670::bigint), (null::uuid, 300000::bigint, 6670::bigint) $$,
  'budget report for admin'
);

select tests.login(tests.id('bob'));
select results_eq(
  $$ select spent_minor from public.budget_report(tests.id('fam'), '2026-10-01') where category_id is null $$,
  $$ values (13670::bigint) $$,
  'report includes the author''s own private expense'
);

select tests.login(tests.id('kid'));
select is((select count(*)::int from public.budget_report(tests.id('fam'), '2026-10-01') where spent_minor > 0), 0,
  'child gets an empty report');

-- ---- categories -----------------------------------------------------------------
select tests.login(tests.id('bob'));
select throws_ok($$
  insert into public.categories (family_id, kind, name, system_key) values (tests.id('fam'), 'expense', 'Fake', 'groceries')
$$, '42501', null, 'cannot create system categories');

select * from finish();
rollback;
