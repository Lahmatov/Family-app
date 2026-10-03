-- Loans: adults/admins only, immutable terms, history as separate rows.
begin;
select plan(15);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.loans (family_id, title, lender, principal_minor, currency, annual_rate, term_months, first_payment_on)
  values (tests.id('fam'), 'Mortgage', 'Bank', 20000000, 'EUR', 3.6, 360, '2026-11-01') $$, 'adult adds a loan');
select tests.set_id('loan', (select id from public.loans where title = 'Mortgage'));

select throws_ok($$ insert into public.loans (family_id, title, principal_minor, currency, annual_rate, term_months, first_payment_on)
  values (tests.id('fam'), 'Bad', 1000, 'EUR', 3, 0, '2026-11-01') $$, '23514', null, 'term must be positive');
select throws_ok($$ insert into public.loans (family_id, title, principal_minor, currency, annual_rate, term_months, first_payment_on)
  values (tests.id('fam'), 'Bad', 1000, 'EUR', 250, 12, '2026-11-01') $$, '23514', null, 'implausible rate rejected');
select throws_ok($$ update public.loans set principal_minor = 1 where id = tests.id('loan') $$, '42501', null, 'loan terms are immutable');
select lives_ok($$ update public.loans set title = 'Home mortgage' where id = tests.id('loan') $$, 'title can be renamed');

select lives_ok($$ insert into public.loan_rate_changes (loan_id, family_id, effective_from, annual_rate)
  values (tests.id('loan'), tests.id('fam'), '2027-05-01', 4.1) $$, 'record a rate change');
select throws_ok($$ insert into public.loan_rate_changes (loan_id, family_id, effective_from, annual_rate)
  values (tests.id('loan'), tests.id('fam'), '2027-05-01', 4.5) $$, '23505', null, 'one rate change per date');
select lives_ok($$ insert into public.loan_extra_payments (loan_id, family_id, paid_on, amount_minor, strategy)
  values (tests.id('loan'), tests.id('fam'), '2027-01-15', 500000, 'reduce_payment') $$, 'record an extra payment');
select throws_ok($$ insert into public.loan_extra_payments (loan_id, family_id, paid_on, amount_minor)
  values (tests.id('loan'), tests.id('fam'), '2027-01-15', 0) $$, '23514', null, 'extra payment must be positive');
select lives_ok($$ insert into public.loan_payments (loan_id, family_id, installment_no, paid_on)
  values (tests.id('loan'), tests.id('fam'), 1, '2026-11-01') $$, 'mark an installment paid');
select throws_ok($$ insert into public.loan_payments (loan_id, family_id, installment_no, paid_on)
  values (tests.id('loan'), tests.id('fam'), 1, '2026-11-02') $$, '23505', null, 'an installment is paid once');

select tests.login(tests.id('teen'));
select is((select count(*)::int from public.loans) + (select count(*)::int from public.loan_payments), 0, 'child role sees no loans');
select tests.login(tests.id('eve'));
select throws_ok($$ insert into public.loan_payments (loan_id, family_id, installment_no, paid_on)
  values (tests.id('loan'), tests.id('evefam'), 2, '2026-12-01') $$, '23503', null, 'cannot attach rows to another family''s loan');
select tests.login(tests.id('bob'), 'aal1');
select is((select count(*)::int from public.loans), 0, 'no loans without MFA');

select tests.login(tests.id('alice'));
delete from public.loans where id = tests.id('loan');
select tests.logout();
select is((select count(*)::int from public.loan_payments) + (select count(*)::int from public.loan_extra_payments), 0,
  'deleting a loan removes its history');

select * from finish();
rollback;
