-- Apartment hunting: shared by adults, invisible to children/guests/outsiders.
begin;
select plan(18);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('kid',   tests.create_user('kid@example.com'));    -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('kid'), 'child');

select tests.login(tests.id('bob'));
select tests.set_id('l1', gen_random_uuid());
select lives_ok($$
  insert into public.listings (id, family_id, url, source, title, price_minor, area_m2, rooms, lat, lng)
  values (tests.id('l1'), tests.id('fam'), 'https://www.idealista.pt/imovel/123/', 'idealista', 'T2 Lisboa', 32000000, 78.5, 2, 38.72, -9.14)
$$, 'adult adds a listing');
select is((select created_by from public.listings where id = tests.id('l1')), tests.id('bob'), 'created_by from session');

select throws_ok($$ insert into public.listings (family_id, url) values (tests.id('fam'), 'https://www.idealista.pt/imovel/123/') $$,
  '23505', null, 'same link cannot be added twice');
select throws_ok($$ insert into public.listings (family_id, url) values (tests.id('fam'), 'javascript:alert(1)') $$,
  '23514', null, 'only https links');
select throws_ok($$ insert into public.listings (family_id, url) values (tests.id('fam'), 'http://example.com/a') $$,
  '23514', null, 'plain http rejected');
select throws_ok($$ insert into public.listings (family_id, url, lat) values (tests.id('fam'), 'https://example.com/b', 38.7) $$,
  '23514', null, 'lat without lng rejected');
select throws_ok($$ insert into public.listings (family_id, url, created_by) values (tests.id('fam'), 'https://example.com/c', tests.id('alice')) $$,
  '42501', null, 'cannot spoof author');

-- criteria & answers
insert into public.listing_criteria (family_id, name, weight) values (tests.id('fam'), 'Balcony', 4);
select tests.set_id('c1', (select id from public.listing_criteria where name = 'Balcony'));
select lives_ok($$
  insert into public.listing_answers (listing_id, criterion_id, family_id, answer)
  values (tests.id('l1'), tests.id('c1'), tests.id('fam'), 'yes')
$$, 'answer a criterion');

-- comments
select lives_ok($$ insert into public.listing_comments (listing_id, family_id, body) values (tests.id('l1'), tests.id('fam'), 'Nice light, noisy street') $$,
  'comment on a listing');

-- cross-family tampering
select tests.login(tests.id('eve'));
insert into public.listing_criteria (family_id, name) values (tests.id('evefam'), 'Garden');
select tests.set_id('ec1', (select id from public.listing_criteria where name = 'Garden'));
select throws_ok($$
  insert into public.listing_answers (listing_id, criterion_id, family_id, answer)
  values (tests.id('l1'), tests.id('ec1'), tests.id('evefam'), 'yes')
$$, '23503', null, 'cannot answer on another family''s listing');
select is((select count(*)::int from public.listings), 0, 'outsider sees no listings');
select is((select count(*)::int from public.listing_comments), 0, 'outsider sees no comments');

-- role gates
select tests.login(tests.id('kid'));
select is((select count(*)::int from public.listings), 0, 'child sees no listings');
select throws_ok($$ insert into public.listings (family_id, url) values (tests.id('fam'), 'https://example.com/kid') $$,
  '42501', null, 'child cannot add listings');

select tests.login(tests.id('alice'), 'aal1');
select is((select count(*)::int from public.listings), 0, 'no listings without MFA');

-- shared editing and deletion rules
select tests.login(tests.id('alice'));
select is((select count(*)::int from public.listings), 1, 'admin sees the listing');
update public.listings set status = 'to_visit' where id = tests.id('l1');

select tests.login(tests.id('bob'));
select tests.set_id('l2', gen_random_uuid());
insert into public.listings (id, family_id, url) values (tests.id('l2'), tests.id('fam'), 'https://example.com/l2');
select tests.login(tests.id('alice'));
delete from public.listings where id = tests.id('l2');
select tests.logout();
select is((select status::text from public.listings where id = tests.id('l1')), 'to_visit', 'any adult can update status');
select is((select count(*)::int from public.listings where id = tests.id('l2')), 0, 'admin can delete another member''s listing');

select * from finish();
rollback;
