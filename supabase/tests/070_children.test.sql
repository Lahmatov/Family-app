-- Children's health data: adults/admins only, isolated per family, validated.
begin;
select plan(18);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child role
select tests.set_id('gran',  tests.create_user('gran@example.com'));   -- guest
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');
select tests.add_member(tests.id('fam'), tests.id('gran'), 'guest');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.children (family_id, name, birth_date, sex, blood_type, allergies)
  values (tests.id('fam'), 'Mia', current_date - 400, 'female', 'A+', 'peanuts') $$, 'adult adds a child');
select tests.set_id('mia', (select id from public.children where name = 'Mia'));

select throws_ok($$ insert into public.children (family_id, name, birth_date) values (tests.id('fam'), 'Future', current_date + 30) $$,
  '23514', null, 'birth date cannot be in the future');
select throws_ok($$ insert into public.children (family_id, name, birth_date, blood_type) values (tests.id('fam'), 'X', current_date - 5, 'Z+') $$,
  '23514', null, 'unknown blood type rejected');

select lives_ok($$ insert into public.child_vaccinations (child_id, family_id, vaccine_code, dose, given_on)
  values (tests.id('mia'), tests.id('fam'), 'hexa', 1, current_date - 300) $$, 'record a vaccination');
select throws_ok($$ insert into public.child_vaccinations (child_id, family_id, vaccine_code, dose, given_on)
  values (tests.id('mia'), tests.id('fam'), 'hexa', 1, current_date - 200) $$,
  '23505', null, 'same dose cannot be recorded twice');
select throws_ok($$ insert into public.child_vaccinations (child_id, family_id, vaccine_code, dose, given_on)
  values (tests.id('mia'), tests.id('fam'), 'HEXA; drop', 2, current_date) $$,
  '23514', null, 'vaccine code format enforced');

select lives_ok($$ insert into public.child_measurements (child_id, family_id, measured_on, height_mm, weight_g)
  values (tests.id('mia'), tests.id('fam'), current_date - 30, 780, 10200) $$, 'record growth');
select throws_ok($$ insert into public.child_measurements (child_id, family_id, measured_on) values (tests.id('mia'), tests.id('fam'), current_date) $$,
  '23514', null, 'a measurement needs at least one value');
select throws_ok($$ insert into public.child_measurements (child_id, family_id, measured_on, weight_g) values (tests.id('mia'), tests.id('fam'), current_date, 50) $$,
  '23514', null, 'implausible weight rejected');

select lives_ok($$ insert into public.child_illnesses (child_id, family_id, title, started_on, ended_on)
  values (tests.id('mia'), tests.id('fam'), 'Otitis', current_date - 20, current_date - 15) $$, 'record an illness');
select throws_ok($$ insert into public.child_illnesses (child_id, family_id, title, started_on, ended_on)
  values (tests.id('mia'), tests.id('fam'), 'Bad dates', current_date - 5, current_date - 10) $$,
  '23514', null, 'illness cannot end before it starts');

-- cross-family tampering: record points at Mia but claims Eve's family
select tests.login(tests.id('eve'));
select throws_ok($$ insert into public.child_measurements (child_id, family_id, measured_on, weight_g)
  values (tests.id('mia'), tests.id('evefam'), current_date, 9000) $$, '23503', null, 'cannot attach records to another family''s child');
select is((select count(*)::int from public.children) + (select count(*)::int from public.child_vaccinations), 0,
  'outsider sees nothing');

-- role gates
select tests.login(tests.id('teen'));
select is((select count(*)::int from public.children), 0, 'child role cannot read health data');
select tests.login(tests.id('gran'));
select is((select count(*)::int from public.child_illnesses), 0, 'guest cannot read health data');
select tests.login(tests.id('bob'), 'aal1');
select is((select count(*)::int from public.children), 0, 'no health data without MFA');

-- delete rules
select tests.login(tests.id('bob'));
delete from public.children where id = tests.id('mia');
select tests.login(tests.id('alice'));
select is((select count(*)::int from public.children), 1, 'an adult cannot delete a child profile');
delete from public.children where id = tests.id('mia');
select tests.logout();
select is((select count(*)::int from public.child_vaccinations) + (select count(*)::int from public.child_measurements), 0,
  'admin deletes the profile and all its records cascade');

select * from finish();
rollback;
