-- Vacation planning: adults plan together, children and outsiders see nothing, bad data is rejected.
begin;
select plan(13);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.trips (family_id, title, destination, starts_on, ends_on, currency, budget_minor)
  values (tests.id('fam'), 'Algarve', 'Faro', date '2027-07-10', date '2027-07-20', 'EUR', 250000) $$, 'adult creates a trip');
select tests.set_id('t1', (select id from public.trips where title = 'Algarve'));

select throws_ok($$ insert into public.trips (family_id, title, starts_on, ends_on, currency)
  values (tests.id('fam'), 'Backwards', date '2027-07-10', date '2027-07-09', 'EUR') $$, '23514', null, 'end cannot precede start');
select throws_ok($$ insert into public.trips (family_id, title, starts_on, ends_on, currency, budget_minor)
  values (tests.id('fam'), 'Negative', date '2027-07-10', date '2027-07-12', 'EUR', -1) $$, '23514', null, 'budget cannot be negative');

select lives_ok($$ insert into public.trip_items (trip_id, family_id, kind, title, day, cost_minor, link)
  values (tests.id('t1'), tests.id('fam'), 'stay', 'Hotel', date '2027-07-10', 90000, 'https://example.com/hotel') $$, 'add an item');
select throws_ok($$ insert into public.trip_items (trip_id, family_id, title, link)
  values (tests.id('t1'), tests.id('fam'), 'Bad link', 'javascript:alert(1)') $$, '23514', null, 'only https links');
select throws_ok($$ insert into public.trip_items (trip_id, family_id, title, cost_minor)
  values (tests.id('t1'), tests.id('fam'), 'Free money', -5) $$, '23514', null, 'cost cannot be negative');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.trip_items), 1, 'the other adult sees the item');
select lives_ok($$ update public.trip_items set is_done = true $$, 'any adult ticks an item off');
select throws_ok($$ update public.trip_items set created_by = tests.id('alice') $$, '42501', null, 'author cannot be rewritten');

select tests.login(tests.id('teen'));
select is((select count(*)::int from public.trips) + (select count(*)::int from public.trip_items), 0, 'child sees no trips');

select tests.login(tests.id('eve'));
select is((select count(*)::int from public.trips) + (select count(*)::int from public.trip_items), 0, 'outsider sees nothing');
select throws_ok($$ insert into public.trip_items (trip_id, family_id, title) values (tests.id('t1'), tests.id('evefam'), 'x') $$,
  '23503', null, 'cannot attach items to another family''s trip');

select tests.login(tests.id('bob'));
delete from public.trips where id = tests.id('t1');
select is((select count(*)::int from public.trip_items), 0, 'deleting a trip removes its items');

select * from finish();
rollback;
