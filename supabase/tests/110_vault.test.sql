-- Encrypted vault: key custody, sharing, items, member removal and rotation.
-- All blobs are opaque random bytes here; the cryptography itself is tested in FamilyCore.
begin;
select plan(47);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('carol', tests.create_user('carol@example.com'));  -- adult, never receives the key
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('carol'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');

-- ---- identities ------------------------------------------------------------------
select tests.login(tests.id('alice'));
select lives_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('alice'), decode(repeat('a1', 32), 'hex')) $$,
  'alice publishes her public key');
select throws_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('alice'), decode(repeat('a2', 32), 'hex')) $$,
  '23505', null, 'a second identity cannot silently replace the first');
select throws_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('bob'), decode(repeat('b2', 32), 'hex')) $$,
  '42501', null, 'cannot publish a key for someone else');
select throws_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('alice'), decode(repeat('a1', 5), 'hex')) $$,
  '23514', null, 'a public key must be 32 bytes');
select lives_ok($$ insert into public.vault_identity_backups (user_id, blob) values (tests.id('alice'), decode(repeat('ee', 61), 'hex')) $$,
  'alice stores her encrypted identity backup');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('bob'), decode(repeat('b2', 32), 'hex')) $$, 'bob publishes his key');
select is((select count(*)::int from public.vault_identities), 2, 'bob sees alice''s and his own public key');
select is((select count(*)::int from public.vault_identity_backups), 0, 'nobody can read another person''s identity backup');
select tests.login(tests.id('carol'));
select lives_ok($$ insert into public.vault_identities (user_id, public_key) values (tests.id('carol'), decode(repeat('c3', 32), 'hex')) $$, 'carol publishes her key');
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.vault_identities where user_id <> tests.id('eve')), 0, 'outsiders see no public keys');

-- ---- keys -------------------------------------------------------------------------
select tests.login(tests.id('teen'));
select throws_ok($$ select public.vault_create_key(gen_random_uuid(), tests.id('fam'), 'family', decode(repeat('cd', 94), 'hex')) $$,
  '42501', null, 'a child cannot create the family key');
select tests.login(tests.id('alice'), 'aal1');
select throws_ok($$ select public.vault_create_key(gen_random_uuid(), tests.id('fam'), 'family', decode(repeat('cd', 94), 'hex')) $$,
  '28000', null, 'creating a key needs the second factor');

select tests.login(tests.id('alice'));
select tests.set_id('fkey', public.vault_create_key(gen_random_uuid(), tests.id('fam'), 'family', decode(repeat('cd', 94), 'hex')));
select ok(tests.id('fkey') is not null, 'alice creates the family key and holds it');
select throws_ok($$ select public.vault_create_key(gen_random_uuid(), tests.id('fam'), 'family', decode(repeat('cd', 94), 'hex')) $$,
  '23505', null, 'there is only one family key');
select is((select count(*)::int from public.vault_keys), 1, 'alice sees the key she holds');

select tests.login(tests.id('bob'));
select is((select count(*)::int from public.vault_keys), 0, 'bob does not see a key he has no wrap for');
select tests.set_id('bkey', public.vault_create_key(gen_random_uuid(), tests.id('fam'), 'personal', decode(repeat('cd', 94), 'hex')));
select tests.login(tests.id('alice'));
select is((select count(*)::int from public.vault_keys where id = tests.id('bkey')), 0, 'an admin cannot see someone else''s personal key');

-- ---- sharing -----------------------------------------------------------------------
select tests.login(tests.id('carol'));
select throws_ok($$ select public.vault_share_key(tests.id('fkey'), tests.id('carol'), decode(repeat('cd', 94), 'hex')) $$,
  'P0002', null, 'someone without the key cannot hand it out');
select tests.login(tests.id('alice'));
select throws_ok($$ select public.vault_share_key(tests.id('fkey'), tests.id('teen'), decode(repeat('cd', 94), 'hex')) $$,
  '42501', null, 'the key cannot be shared with a child');
select throws_ok($$ select public.vault_share_key(tests.id('fkey'), tests.id('eve'), decode(repeat('cd', 94), 'hex')) $$,
  '42501', null, 'the key cannot be shared outside the family');
select lives_ok($$ select public.vault_share_key(tests.id('fkey'), tests.id('bob'), decode(repeat('de', 94), 'hex')) $$, 'alice shares the key with bob');
select throws_ok($$ select public.vault_share_key(tests.id('fkey'), tests.id('bob'), decode(repeat('de', 94), 'hex')) $$,
  '23505', null, 'sharing twice is refused');
select tests.login(tests.id('bob'));
select is((select count(*)::int from public.vault_key_wraps where key_id = tests.id('fkey')), 1, 'bob sees only his own wrap');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.vault_key_holders(tests.id('fkey'))), 2, 'a holder can list the holders (alice and bob)');
select tests.login(tests.id('carol'));
select throws_ok($$ select * from public.vault_key_holders(tests.id('fkey')) $$, 'P0002', null, 'a non-holder cannot list holders');
select tests.login(tests.id('bob'));
select is((select count(*)::int from public.vault_key_holders(tests.id('bkey'))), 1, 'a personal key has exactly one holder');

-- ---- items ---------------------------------------------------------------------------
select tests.set_id('item1', gen_random_uuid());
select tests.login(tests.id('alice'));
select lives_ok($$ insert into public.vault_items (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  values (tests.id('item1'), tests.id('fam'), tests.id('fkey'), decode(repeat('11', 70), 'hex'), decode(repeat('22', 62), 'hex'),
          tests.id('fam') || '/' || tests.id('item1'), 1000) $$, 'alice stores an encrypted document');
select throws_ok($$ insert into public.vault_items (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  values (gen_random_uuid(), tests.id('fam'), tests.id('fkey'), decode(repeat('11', 70), 'hex'), decode(repeat('22', 62), 'hex'),
          'elsewhere/file', 1000) $$, '23514', null, 'the storage path must be <family>/<item>');
select tests.login(tests.id('bob'));
select is((select count(*)::int from public.vault_items), 1, 'bob (holder) sees the document');
select tests.login(tests.id('carol'));
select is((select count(*)::int from public.vault_items), 0, 'carol (adult, no wrap) sees nothing');
select throws_ok($$ insert into public.vault_items (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  values (gen_random_uuid(), tests.id('fam'), tests.id('fkey'), decode(repeat('11', 70), 'hex'), decode(repeat('22', 62), 'hex'),
          tests.id('fam') || '/' || gen_random_uuid(), 10) $$, '42501', null, 'cannot add to a vault whose key you do not hold');

select tests.login(tests.id('bob'));
select throws_ok($$ update public.vault_items set wrapped_item_key = decode(repeat('33', 62), 'hex') where id = tests.id('item1') $$,
  '42501', null, 'item keys are re-wrapped only through the rotation function');
select lives_ok($$ update public.vault_items set encrypted_meta = decode(repeat('44', 70), 'hex') where id = tests.id('item1') $$,
  'a holder can update the encrypted metadata');

-- ---- member removal and rotation ------------------------------------------------------
select tests.logout();
delete from public.family_members where family_id = tests.id('fam') and user_id = tests.id('bob');
select is((select count(*)::int from public.vault_key_wraps where user_id = tests.id('bob') and family_id = tests.id('fam')), 0,
  'removing a member deletes their key wraps');
select ok((select rotation_needed from public.vault_keys where id = tests.id('fkey')), 'the family key is flagged for rotation');
select tests.login(tests.id('bob'));
select is((select count(*)::int from public.vault_items), 0, 'the removed member cannot read the documents any more');

select tests.login(tests.id('carol'));
select throws_ok($$ select public.vault_rotate_family_key(gen_random_uuid(), tests.id('fam'), '[]'::jsonb, '[]'::jsonb) $$,
  '42501', null, 'only an admin can rotate');
select tests.login(tests.id('alice'));
select throws_ok($$ select public.vault_rotate_family_key(gen_random_uuid(), tests.id('fam'),
  jsonb_build_array(jsonb_build_object('user_id', tests.id('alice'), 'wrapped', encode(decode(repeat('cd', 94), 'hex'), 'base64'))),
  '[]'::jsonb) $$, '22023', null, 'rotation must re-wrap every item');
select throws_ok($$ select public.vault_rotate_family_key(gen_random_uuid(), tests.id('fam'),
  jsonb_build_array(jsonb_build_object('user_id', tests.id('eve'), 'wrapped', encode(decode(repeat('cd', 94), 'hex'), 'base64'))),
  jsonb_build_array(jsonb_build_object('id', tests.id('item1'), 'wrapped_item_key', encode(decode(repeat('55', 62), 'hex'), 'base64')))) $$,
  '42501', null, 'rotation cannot hand the new key to an outsider');
select tests.set_id('newkey', public.vault_rotate_family_key(gen_random_uuid(), tests.id('fam'),
  jsonb_build_array(jsonb_build_object('user_id', tests.id('alice'), 'wrapped', encode(decode(repeat('cd', 94), 'hex'), 'base64'))),
  jsonb_build_array(jsonb_build_object('id', tests.id('item1'), 'wrapped_item_key', encode(decode(repeat('55', 62), 'hex'), 'base64')))));
select is((select version from public.vault_keys where id = tests.id('newkey')), 2, 'rotation creates version 2');
select is((select key_id from public.vault_items where id = tests.id('item1')), tests.id('newkey'), 'the item moved to the new key');
select is((select count(*)::int from public.vault_keys where kind = 'family'), 1, 'the old family key is gone');

-- ---- storage and identity reset ----------------------------------------------------------
select tests.login(tests.id('alice'));
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id)
  values ('vault', tests.id('fam') || '/' || tests.id('item1'), tests.id('alice')::text) $$, 'the ciphertext is uploaded to the family folder');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id)
  values ('vault', tests.id('evefam') || '/' || gen_random_uuid(), tests.id('alice')::text) $$, '42501', null,
  'no uploads into another family''s folder');
select is((select count(*)::int from storage.objects where bucket_id = 'vault'), 1, 'the holder can read the blob through its item');
select tests.login(tests.id('carol'));
select is((select count(*)::int from storage.objects where bucket_id = 'vault'), 0, 'an adult without the key cannot read the blob');
select tests.login(tests.id('alice'));
delete from public.vault_identities where user_id = tests.id('alice');
select tests.logout();
select is((select count(*)::int from public.vault_key_wraps where user_id = tests.id('alice')), 0, 'resetting an identity deletes the wraps made for the old key');

select * from finish();
rollback;
