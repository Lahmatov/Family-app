-- Fixes that came out of code review: serialisation of admin changes, and the app's write paths.
begin;
select plan(13);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');

-- Concurrency cannot be reproduced in one transaction; pin the invariant instead: every function that can change
-- the set of admins takes the family row lock before it counts admins.
select matches(pg_get_functiondef('public.approve_request(uuid)'::regprocedure), 'from public\.families where id = v_family for update',
  'approve_request locks the family row');
select matches(pg_get_functiondef('public.leave_family(uuid)'::regprocedure), 'from public\.families where id = p_family for update',
  'leave_family locks the family row');
select matches(pg_get_functiondef('public.request_action(uuid, public.approval_action, jsonb)'::regprocedure), 'from public\.families where id = p_family for update',
  'request_action locks the family row');

-- The app cannot use PostgREST upserts (they put every payload column into DO UPDATE SET, which needs UPDATE on
-- key columns that are not granted). It inserts, and on a duplicate updates only the mutable column.
select tests.login(tests.id('alice'));

insert into public.goals (family_id, title, start_value, target_value) values (tests.id('fam'), 'Goal', 0, 10);
select tests.set_id('goal', (select id from public.goals where title = 'Goal'));
select throws_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on)
  values (tests.id('goal'), tests.id('fam'), 1, current_date) on conflict (goal_id, recorded_on)
  do update set goal_id = excluded.goal_id, family_id = excluded.family_id, value = excluded.value, recorded_on = excluded.recorded_on $$,
  '42501', null, 'a PostgREST-style upsert is refused (this is why the app does not use it)');
select lives_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on) values (tests.id('goal'), tests.id('fam'), 1, current_date) $$, 'goal entry insert');
select throws_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on) values (tests.id('goal'), tests.id('fam'), 2, current_date) $$,
  '23505', null, 'a second reading on the same day is a duplicate');
select lives_ok($$ update public.goal_entries set value = 2 where goal_id = tests.id('goal') and recorded_on = current_date $$, 'and the fallback update works');
select is((select value from public.goal_entries where goal_id = tests.id('goal')), 2.000::numeric, 'the reading was replaced');

select lives_ok($$ insert into public.budgets (family_id, category_id, amount_minor, valid_from) values (tests.id('fam'), null, 1000, date '2026-10-01') $$, 'budget insert');
select throws_ok($$ insert into public.budgets (family_id, category_id, amount_minor, valid_from) values (tests.id('fam'), null, 2000, date '2026-10-01') $$,
  '23505', null, 'a second budget for the same month (no category) is a duplicate');
select lives_ok($$ update public.budgets set amount_minor = 2000 where family_id = tests.id('fam') and category_id is null and valid_from = date '2026-10-01' $$,
  'the fallback update targets a NULL category too');
select is((select amount_minor from public.budgets where family_id = tests.id('fam')), 2000::bigint, 'the budget was replaced');

-- loan payments: ON CONFLICT DO NOTHING needs only INSERT
insert into public.loans (family_id, title, principal_minor, currency, annual_rate, term_months, first_payment_on, loan_type)
  values (tests.id('fam'), 'Car', 100000, 'EUR', 0, 12, date '2026-01-01', 'annuity');
select tests.set_id('loan', (select id from public.loans where title = 'Car'));
insert into public.loan_payments (loan_id, family_id, installment_no, paid_on) values (tests.id('loan'), tests.id('fam'), 1, current_date)
  on conflict (loan_id, installment_no) do nothing;
select lives_ok($$ insert into public.loan_payments (loan_id, family_id, installment_no, paid_on) values (tests.id('loan'), tests.id('fam'), 1, current_date)
  on conflict (loan_id, installment_no) do nothing $$, 'marking an instalment twice is harmless');

select * from finish();
rollback;
