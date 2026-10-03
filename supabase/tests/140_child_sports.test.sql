-- Children's sports calendar: adults only, shape rules, isolation, cascade with the child.
begin;
select plan(12);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child role
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

select tests.login(tests.id('bob'));
insert into public.children (family_id, name, birth_date) values (tests.id('fam'), 'Mia', current_date - 2000);
select tests.set_id('mia', (select id from public.children where name = 'Mia'));

select lives_ok($$ insert into public.child_sports (child_id, family_id, kind, title, weekday, start_minute, duration_minutes, until_date)
  values (tests.id('mia'), tests.id('fam'), 'training', 'Swimming', 2, 1020, 60, current_date + 90) $$, 'weekly training');
select lives_ok($$ insert into public.child_sports (child_id, family_id, kind, title, on_date, start_minute, location)
  values (tests.id('mia'), tests.id('fam'), 'event', 'Tournament', current_date + 10, 540, 'Pavilhão') $$, 'one-off event');

select throws_ok($$ insert into public.child_sports (child_id, family_id, kind, title, start_minute)
  values (tests.id('mia'), tests.id('fam'), 'training', 'No weekday', 600) $$, '23514', null, 'a training needs a weekday');
select throws_ok($$ insert into public.child_sports (child_id, family_id, kind, title, weekday, on_date, start_minute)
  values (tests.id('mia'), tests.id('fam'), 'event', 'Both', 3, current_date, 600) $$, '23514', null, 'an event has a date and no weekday');
select throws_ok($$ insert into public.child_sports (child_id, family_id, kind, title, weekday, start_minute, duration_minutes)
  values (tests.id('mia'), tests.id('fam'), 'training', 'Past midnight', 1, 1400, 120) $$, '23514', null, 'a session cannot run past midnight');
select throws_ok($$ insert into public.child_sports (child_id, family_id, kind, title, weekday, start_minute)
  values (tests.id('mia'), tests.id('fam'), 'training', 'Weekday 8', 8, 600) $$, '23514', null, 'weekday is 1..7');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.child_sports), 2, 'another adult sees the schedule');
select lives_ok($$ update public.child_sports set location = 'Piscina' where title = 'Swimming' $$, 'any adult edits');

select tests.login(tests.id('teen'));
select is((select count(*)::int from public.child_sports), 0, 'child role sees nothing');

select tests.login(tests.id('eve'));
select is((select count(*)::int from public.child_sports), 0, 'outsider sees nothing');
select throws_ok($$ insert into public.child_sports (child_id, family_id, kind, title, weekday, start_minute)
  values (tests.id('mia'), tests.id('evefam'), 'training', 'Hijack', 1, 600) $$, '23503', null, 'cannot attach to another family''s child');

select tests.login(tests.id('alice'));
delete from public.children where id = tests.id('mia');
select tests.logout();
select is((select count(*)::int from public.child_sports), 0, 'deleting the child removes the schedule');

select * from finish();
rollback;
