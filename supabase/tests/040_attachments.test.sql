-- Attachments & storage objects follow the visibility of their parent entity.
begin;
select plan(14);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('kid',   tests.create_user('kid@example.com'));    -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- outsider

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('kid'), 'child');

select set_config('tests.path_shared', tests.id('fam') || '/transaction/' || gen_random_uuid() || '.jpg', true);
select set_config('tests.path_private', tests.id('fam') || '/transaction/' || gen_random_uuid() || '.jpg', true);

select tests.login(tests.id('bob'));
select tests.set_id('t_shared', gen_random_uuid());
select tests.set_id('t_private', gen_random_uuid());
insert into public.transactions (id, family_id, kind, amount_minor, currency, category_id, is_private) values
  (tests.id('t_shared'),  tests.id('fam'), 'expense', 100, 'EUR', tests.category(tests.id('fam'), 'groceries'), false),
  (tests.id('t_private'), tests.id('fam'), 'expense', 200, 'EUR', tests.category(tests.id('fam'), 'groceries'), true);

-- ---- uploads -----------------------------------------------------------------
select lives_ok($$
  insert into storage.objects (bucket_id, name) values ('family-files', current_setting('tests.path_shared'))
$$, 'adult uploads into own family folder');
insert into storage.objects (bucket_id, name) values ('family-files', current_setting('tests.path_private'));

select throws_ok($$
  insert into storage.objects (bucket_id, name) values ('family-files', tests.id('evefam') || '/transaction/' || gen_random_uuid() || '.jpg')
$$, '42501', null, 'cannot upload into another family''s folder');
select throws_ok($$
  insert into storage.objects (bucket_id, name, owner_id) values ('family-files', tests.id('fam') || '/transaction/x.jpg', tests.id('alice')::text)
$$, '42501', null, 'cannot spoof object owner');
select throws_ok($$
  insert into storage.objects (bucket_id, name) values ('family-files', 'not-a-uuid/transaction/x.jpg')
$$, '42501', null, 'malformed path rejected without error leakage');

select is((select count(*)::int from storage.objects), 0, 'unlinked objects are not readable');

-- ---- linking ---------------------------------------------------------------------
select lives_ok($$
  insert into public.attachments (family_id, entity_type, entity_id, storage_path, mime_type, size_bytes) values
    (tests.id('fam'), 'transaction', tests.id('t_shared'),  current_setting('tests.path_shared'),  'image/jpeg', 1000),
    (tests.id('fam'), 'transaction', tests.id('t_private'), current_setting('tests.path_private'), 'image/jpeg', 1000)
$$, 'attachments linked to visible transactions');
select throws_ok($$
  insert into public.attachments (family_id, entity_type, entity_id, storage_path, mime_type, size_bytes)
  values (tests.id('fam'), 'transaction', tests.id('t_shared'), tests.id('evefam') || '/transaction/' || gen_random_uuid() || '.jpg', 'image/jpeg', 1)
$$, '23514', null, 'storage path must be inside the attachment''s family folder');
select throws_ok($$
  insert into public.attachments (family_id, entity_type, entity_id, storage_path, mime_type, size_bytes)
  values (tests.id('fam'), 'transaction', tests.id('t_shared'), tests.id('fam') || '/transaction/' || gen_random_uuid() || '.exe', 'application/x-msdownload', 1)
$$, '23514', null, 'executable uploads rejected');
select is((select count(*)::int from storage.objects), 2, 'author reads both receipts');

-- ---- visibility ---------------------------------------------------------------------
select tests.login(tests.id('alice'));
select is((select count(*)::int from public.attachments), 1, 'admin sees only the shared attachment');
select is((select count(*)::int from storage.objects), 1, 'admin cannot read the private receipt object');

select tests.login(tests.id('kid'));
select is((select count(*)::int from storage.objects), 0, 'child cannot read receipts');

select tests.login(tests.id('eve'));
select is((select count(*)::int from storage.objects), 0, 'outsider cannot read receipts');

-- ---- cascade --------------------------------------------------------------------------
select tests.login(tests.id('bob'));
delete from public.transactions where id = tests.id('t_shared');
select tests.logout();
select is((select count(*)::int from public.attachments where entity_id = tests.id('t_shared')), 0,
  'deleting a transaction removes its attachments');

select * from finish();
rollback;
