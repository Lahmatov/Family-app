-- Families, membership, profiles, MFA enforcement, tenant isolation.
begin;
select plan(26);

select tests.set_id('alice', tests.create_user('alice@example.com', 'Alice'));   -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com', 'Bob'));       -- adult
select tests.set_id('kid',   tests.create_user('kid@example.com', 'Kid'));       -- child
select tests.set_id('eve',   tests.create_user('eve@example.com', 'Eve'));       -- outsider

-- ---- creating a family -----------------------------------------------------
select tests.login_anon();
select throws_ok(
  $$ select public.create_family('Anon family') $$,
  '42501', null, 'anon cannot call create_family'
);

select tests.login(tests.id('alice'), 'aal1');
select throws_ok(
  $$ select public.create_family('No MFA family') $$,
  '28000', 'second factor required', 'create_family requires MFA (aal2)'
);

select tests.login(tests.id('alice'));
select tests.set_id('fam', public.create_family('  Lahmatov  ', 'eur'));
select is((select name from public.families where id = tests.id('fam')), 'Lahmatov', 'family name is trimmed');
select is((select base_currency::text from public.families where id = tests.id('fam')), 'EUR', 'currency upper-cased');
select is(
  (select role::text from public.family_members where family_id = tests.id('fam') and user_id = tests.id('alice')),
  'admin', 'creator becomes admin'
);
select is((select count(*)::int from public.categories where family_id = tests.id('fam')), 18,
  'default categories are seeded');

select throws_ok(
  $$ select public.create_family('', 'EUR') $$,
  '23514', null, 'empty family name rejected'
);

select tests.logout();
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('kid'), 'child');

-- ---- direct writes are impossible -----------------------------------------
select tests.login(tests.id('alice'));
select throws_ok(
  $$ insert into public.family_members (family_id, user_id, role) values (tests.id('fam'), tests.id('eve'), 'admin') $$,
  '42501', null, 'admin cannot insert members directly (must use invitations)'
);
select throws_ok(
  $$ update public.family_members set role = 'admin' where user_id = tests.id('bob') $$,
  '42501', null, 'roles cannot be changed by direct UPDATE'
);
select throws_ok(
  $$ insert into public.families (name) values ('direct') $$,
  '42501', null, 'families cannot be inserted directly'
);
select throws_ok(
  $$ update public.families set base_currency = 'USD' where id = tests.id('fam') $$,
  '42501', null, 'base currency is immutable for clients'
);

-- ---- tenant isolation ------------------------------------------------------
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.families), 0, 'outsider sees no families');
select is((select count(*)::int from public.family_members), 0, 'outsider sees no memberships');
select is((select count(*)::int from public.profiles where id <> tests.id('eve')), 0,
  'outsider sees no other profiles');
update public.families set name = 'pwned' where id = tests.id('fam');
select tests.logout();
select is((select name from public.families where id = tests.id('fam')), 'Lahmatov', 'outsider cannot rename family');

-- ---- MFA gate --------------------------------------------------------------
select tests.login(tests.id('bob'), 'aal1');
select is((select count(*)::int from public.families), 0, 'member without MFA sees nothing');
select is((select count(*)::int from public.profiles), 1, 'without MFA only own profile is visible');

select tests.login(tests.id('bob'));
select is((select count(*)::int from public.profiles), 3, 'member sees co-members profiles');

-- ---- role checks ------------------------------------------------------------
update public.families set name = 'Bob family' where id = tests.id('fam');
select tests.logout();
select is((select name from public.families where id = tests.id('fam')), 'Lahmatov', 'adult cannot rename family');

select tests.login(tests.id('alice'));
update public.families set name = 'Lahmatovy' where id = tests.id('fam');
select tests.logout();
select is((select name from public.families where id = tests.id('fam')), 'Lahmatovy', 'admin can rename family');

-- ---- profiles --------------------------------------------------------------
select tests.login(tests.id('bob'));
update public.profiles set display_name = 'hacked' where id = tests.id('alice');
select throws_ok(
  $$ update public.profiles set id = gen_random_uuid() where id = tests.id('bob') $$,
  '42501', null, 'profile id is not updatable'
);
select tests.logout();
select is((select display_name from public.profiles where id = tests.id('alice')), 'Alice',
  'cannot edit someone else''s profile');

-- ---- leaving ---------------------------------------------------------------
select tests.login(tests.id('alice'));
select throws_ok(
  $$ select public.leave_family(tests.id('fam')) $$,
  '23514', null, 'last admin cannot leave while others remain'
);

select tests.login(tests.id('kid'));
select lives_ok($$ select public.leave_family(tests.id('fam')) $$, 'a child can leave');
select tests.logout();
select is((select count(*)::int from public.family_members where family_id = tests.id('fam')), 2,
  'membership removed after leaving');

select tests.set_id('solo', tests.create_family(tests.id('eve'), 'Solo'));
select tests.login(tests.id('eve'));
select public.leave_family(tests.id('solo'));
select tests.logout();
select ok(not exists (select 1 from public.families where id = tests.id('solo')), 'sole member leaving deletes the family');

select * from finish();
rollback;
