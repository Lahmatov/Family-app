-- GDPR: export (access / portability) and erasure of an account.
begin;
select plan(23);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- alone in her family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');

-- fixtures that need the superuser: vault, an attachment, an invitation to bob's address
select tests.set_id('bobkey', gen_random_uuid());
select tests.set_id('bobitem', gen_random_uuid());
select tests.set_id('evekey', gen_random_uuid());
select tests.set_id('eveitem', gen_random_uuid());
select tests.set_id('eveatt', gen_random_uuid());
insert into public.vault_identities (user_id, public_key) values (tests.id('bob'), decode(repeat('b2', 32), 'hex'));
insert into public.vault_keys (id, family_id, kind, owner_id) values (tests.id('bobkey'), tests.id('fam'), 'personal', tests.id('bob'));
insert into public.vault_key_wraps (key_id, user_id, family_id, wrapped) values (tests.id('bobkey'), tests.id('bob'), tests.id('fam'), decode(repeat('cc', 100), 'hex'));
insert into public.vault_items (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  values (tests.id('bobitem'), tests.id('fam'), tests.id('bobkey'), decode(repeat('dd', 40), 'hex'), decode(repeat('ee', 60), 'hex'),
          tests.id('fam')::text || '/' || tests.id('bobitem')::text, 10);
insert into public.vault_keys (id, family_id, kind) values (tests.id('evekey'), tests.id('evefam'), 'family');
insert into public.vault_items (id, family_id, key_id, encrypted_meta, wrapped_item_key, storage_path, size_bytes)
  values (tests.id('eveitem'), tests.id('evefam'), tests.id('evekey'), decode(repeat('dd', 40), 'hex'), decode(repeat('ee', 60), 'hex'),
          tests.id('evefam')::text || '/' || tests.id('eveitem')::text, 10);
insert into public.attachments (id, family_id, entity_type, entity_id, storage_path, mime_type, size_bytes)
  values (tests.id('eveatt'), tests.id('evefam'), 'transaction', gen_random_uuid(),
          tests.id('evefam')::text || '/transaction/' || tests.id('eveatt')::text || '.jpg', 'image/jpeg', 100);
insert into public.family_invitations (family_id, email, role) values (tests.id('evefam'), 'bob@example.com', 'adult');

-- ---- export -----------------------------------------------------------------------
select tests.login(tests.id('alice'));
insert into public.goals (family_id, title, start_value, target_value, is_private)
  values (tests.id('fam'), 'Alice secret goal', 0, 10, true);
select tests.login(tests.id('bob'));
insert into public.trips (family_id, title, starts_on, ends_on, currency)
  values (tests.id('fam'), 'Bob trip', date '2027-07-10', date '2027-07-12', 'EUR');
insert into public.goals (family_id, title, start_value, target_value) values (tests.id('fam'), 'Shared goal', 0, 10);

select is((public.export_my_data() -> 'profile' ->> 'id')::uuid, tests.id('bob'), 'export contains the caller''s profile');
select is(jsonb_array_length(public.export_my_data() -> 'trips'), 1, 'export contains family tables');
select is((select count(*)::int from jsonb_array_elements(public.export_my_data() -> 'goals') g where g ->> 'title' = 'Alice secret goal'), 0,
  'export never includes another person''s private goal');
select is((select count(*)::int from jsonb_array_elements(public.export_my_data() -> 'goals') g where g ->> 'title' = 'Shared goal'), 1,
  'export includes shared goals');
select is(jsonb_array_length(public.export_my_data() -> 'families'), 1, 'only the caller''s families');

select tests.login(tests.id('bob'), 'aal1');
select throws_ok($$ select public.export_my_data() $$, '28000', null, 'export needs the second factor');
select throws_ok($$ select public.account_erasure_plan() $$, '28000', null, 'plan needs the second factor');
select throws_ok($$ select public.delete_my_account() $$, '28000', null, 'erasure needs the second factor');

select tests.login(tests.id('eve'));
select is(jsonb_array_length(public.export_my_data() -> 'trips'), 0, 'an outsider''s export has none of bob''s trips');
select tests.login_anon();
select throws_ok($$ select public.export_my_data() $$, '42501', null, 'anon cannot export');
select tests.logout();

-- ---- plan --------------------------------------------------------------------------
select tests.login(tests.id('alice'));
select is(jsonb_array_length(public.account_erasure_plan() -> 'blockers'), 1, 'the only admin of a family with others is told to hand over first');
select throws_ok($$ select public.delete_my_account() $$, '23514', null, 'the only admin cannot erase the account while others remain');

select tests.login(tests.id('bob'));
select is(jsonb_array_length(public.account_erasure_plan() -> 'blockers'), 0, 'a regular adult has no blockers');
select is((select count(*)::int from jsonb_array_elements(public.account_erasure_plan() -> 'files') f where f ->> 'bucket' = 'vault'), 1,
  'bob''s personal vault file is listed for removal');
select tests.login(tests.id('eve'));
select is(jsonb_array_length(public.account_erasure_plan() -> 'files'), 2, 'a sole member''s attachment and vault file are listed');

-- ---- erasure -----------------------------------------------------------------------
select tests.login(tests.id('bob'));
select lives_ok($$ select public.delete_my_account() $$, 'bob erases his account');
select tests.logout();
select is((select count(*)::int from auth.users where id = tests.id('bob')), 0, 'the account is gone');
select is((select count(*)::int from public.profiles where id = tests.id('bob')) + (select count(*)::int from public.vault_identities where user_id = tests.id('bob')), 0,
  'profile and vault identity are gone');
select is((select count(*)::int from public.vault_items where id = tests.id('bobitem')), 0, 'bob''s personal vault item is gone');
select is((select count(*)::int from public.family_invitations where email = 'bob@example.com'), 0, 'invitations to his address are gone');
select is((select count(*)::int from public.trips where title = 'Bob trip' and created_by is null), 1,
  'what he created for the family stays, no longer attributed to him');
select ok((select count(*) from public.audit_log where family_id = tests.id('fam')) > 0
          and not exists (select 1 from public.audit_log where actor_id = tests.id('bob')), 'audit trail stays, his identity is removed from it');

select tests.login(tests.id('eve'));
select public.delete_my_account();
select tests.logout();
select is((select count(*)::int from public.families where id = tests.id('evefam')), 0, 'a sole member takes the family with them');

select * from finish();
rollback;
