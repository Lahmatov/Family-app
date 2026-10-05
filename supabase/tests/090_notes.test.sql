-- Notes: shared among adults, private ones author-only, privacy immutable.
begin;
select plan(12);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.notes (family_id, title, body) values (tests.id('fam'), 'Wi-Fi', 'password on the fridge') $$,
  'adult writes a shared note');
select lives_ok($$ insert into public.notes (family_id, title, body, is_private) values (tests.id('fam'), 'Gift idea', 'secret', true) $$,
  'adult writes a private note');
select throws_ok($$ insert into public.notes (family_id, title, body) values (tests.id('fam'), '  ', '') $$,
  '23514', null, 'an empty note is rejected');
select throws_ok($$ insert into public.notes (family_id, title, created_by) values (tests.id('fam'), 'spoof', tests.id('alice')) $$,
  '42501', null, 'cannot spoof the author');
select throws_ok($$ update public.notes set is_private = false where title = 'Gift idea' $$,
  '42501', null, 'privacy cannot be changed after creation');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.notes), 1, 'admin sees the shared note only');
update public.notes set pinned = true where title = 'Wi-Fi';
select is((select pinned from public.notes where title = 'Wi-Fi'), true, 'admin can pin a shared note');
update public.notes set body = 'hacked' where title = 'Gift idea';
delete from public.notes where title = 'Gift idea';

select tests.login(tests.id('teen'));
select is((select count(*)::int from public.notes), 0, 'child role sees no notes');
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.notes), 0, 'outsider sees nothing');
select tests.login(tests.id('bob'), 'aal1');
select is((select count(*)::int from public.notes), 0, 'no notes without MFA');

select tests.logout();
select is((select body from public.notes where title = 'Gift idea'), 'secret', 'admin can neither edit nor delete a private note');
select is((select count(*)::int from public.notes), 2, 'both notes still exist');

select * from finish();
rollback;
