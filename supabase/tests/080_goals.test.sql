-- Goals: shared among adults, private ones visible to the author only.
begin;
select plan(16);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.goals (family_id, kind, title, unit, start_value, target_value, deadline)
  values (tests.id('fam'), 'savings', 'Holiday fund', 'EUR', 0, 3000, current_date + 200) $$, 'adult creates a shared goal');
select tests.set_id('g1', (select id from public.goals where title = 'Holiday fund'));
select lives_ok($$ insert into public.goals (family_id, kind, title, unit, start_value, target_value, is_private)
  values (tests.id('fam'), 'weight', 'Lose weight', 'kg', 90, 80, true) $$, 'adult creates a private goal');
select tests.set_id('g2', (select id from public.goals where title = 'Lose weight'));

select throws_ok($$ insert into public.goals (family_id, title, start_value, target_value) values (tests.id('fam'), 'Same', 5, 5) $$,
  '23514', null, 'target must differ from start');
select throws_ok($$ insert into public.goals (family_id, title, start_value, target_value, deadline)
  values (tests.id('fam'), 'Past', 0, 5, current_date - 10) $$, '23514', null, 'deadline cannot precede the start date');

select lives_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on)
  values (tests.id('g1'), tests.id('fam'), 450, current_date) $$, 'log progress');
select throws_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on)
  values (tests.id('g1'), tests.id('fam'), 500, current_date) $$, '23505', null, 'one entry per day');
select lives_ok($$ insert into public.goal_entries (goal_id, family_id, value) values (tests.id('g2'), tests.id('fam'), 88.4) $$,
  'log progress on a private goal');

-- visibility
select tests.login(tests.id('alice'));
select is((select count(*)::int from public.goals), 1, 'admin sees the shared goal but not the private one');
select is((select count(*)::int from public.goal_entries where goal_id = tests.id('g2')), 0, 'private goal entries are hidden too');
select throws_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on)
  values (tests.id('g2'), tests.id('fam'), 70, current_date - 1) $$, '42501', null, 'cannot log on someone else''s private goal');
select lives_ok($$ insert into public.goal_entries (goal_id, family_id, value, recorded_on)
  values (tests.id('g1'), tests.id('fam'), 600, current_date - 1) $$, 'any adult can log on a shared goal');

update public.goals set title = 'Admin edit' where id = tests.id('g1');
select tests.login(tests.id('teen'));
select is((select count(*)::int from public.goals), 0, 'child role sees no goals');
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.goals) + (select count(*)::int from public.goal_entries), 0, 'outsider sees nothing');
select throws_ok($$ insert into public.goal_entries (goal_id, family_id, value) values (tests.id('g1'), tests.id('evefam'), 1) $$,
  '42501', null, 'cannot attach entries to another family''s goal');

select tests.logout();
select is((select title from public.goals where id = tests.id('g1')), 'Admin edit', 'admin can edit a shared goal');
select tests.login(tests.id('alice'));
delete from public.goals where id = tests.id('g2');
select tests.logout();
select is((select count(*)::int from public.goals where id = tests.id('g2')), 1, 'admin cannot delete a private goal of someone else');

select * from finish();
rollback;
