-- Four-eyes approvals for critical actions; invitations bound to email.
begin;
select plan(27);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('anna',  tests.create_user('anna@example.com'));   -- second admin (added later)
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('nina',  tests.create_user('nina@example.com'));   -- invitee
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- outsider, admin of own family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');

-- ---- single admin: actions execute immediately ------------------------------
select tests.login(tests.id('alice'));
select is(
  public.request_action(tests.id('fam'), 'invite_member', '{"email":" Anna@Example.com ","role":"admin"}') ->> 'status',
  'executed', 'with a single admin the action executes immediately'
);
select is(
  (select email from public.family_invitations where family_id = tests.id('fam')),
  'anna@example.com', 'invitation created with normalised email'
);
select throws_ok(
  $$ select public.request_action(tests.id('fam'), 'invite_member', '{"email":"anna@example.com","role":"adult"}') $$,
  '23505', null, 'duplicate open invitation is rejected'
);
select throws_ok(
  $$ select public.request_action(tests.id('fam'), 'invite_member', '{"email":"bob@example.com","role":"adult"}') $$,
  '23505', null, 'cannot invite an existing member'
);
select throws_ok(
  $$ select public.request_action(tests.id('fam'), 'invite_member', '{"email":"x@example.com","role":"superuser"}') $$,
  '22P02', null, 'unknown role rejected'
);
select throws_ok(
  $$ select public.request_action(tests.id('fam'), 'change_role', format('{"user_id":"%s","role":"adult"}', tests.id('alice'))::jsonb) $$,
  '23514', null, 'the last admin cannot be demoted'
);

-- ---- invitations ------------------------------------------------------------
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.family_invitations), 0, 'outsider sees no invitations');
select tests.logout();
select tests.set_id('inv', (select id from public.family_invitations where family_id = tests.id('fam')));

select tests.login(tests.id('eve'));
select throws_ok(
  $$ select public.accept_invitation(tests.id('inv')) $$,
  'P0002', null, 'invitation for another email cannot be accepted'
);

select tests.login(tests.id('anna'), 'aal1');
select is((select count(*)::int from public.family_invitations), 1, 'invitee sees own pending invitation');
select throws_ok(
  $$ select public.accept_invitation(tests.id('inv')) $$,
  '28000', null, 'accepting requires MFA'
);

select tests.login(tests.id('anna'));
select is(public.accept_invitation(tests.id('inv')), tests.id('fam'), 'invitee accepts and joins');
select is(
  (select role::text from public.family_members where family_id = tests.id('fam') and user_id = tests.id('anna')),
  'admin', 'joined with the invited role'
);
select throws_ok(
  $$ select public.accept_invitation(tests.id('inv')) $$,
  '55000', null, 'invitation cannot be reused'
);

-- ---- two admins: approval required -------------------------------------------
select tests.login(tests.id('bob'));
select throws_ok(
  $$ select public.request_action(tests.id('fam'), 'remove_member', format('{"user_id":"%s"}', tests.id('alice'))::jsonb) $$,
  '42501', null, 'non-admin cannot request critical actions'
);
select is((select count(*)::int from public.approval_requests), 0, 'non-admin cannot see approval requests');

select tests.login(tests.id('alice'));
select tests.set_id('req', (public.request_action(
  tests.id('fam'), 'remove_member', format('{"user_id":"%s"}', tests.id('bob'))::jsonb) ->> 'id')::uuid);
select is((select status::text from public.approval_requests where id = tests.id('req')), 'pending',
  'with two admins the request stays pending');
select ok(exists (select 1 from public.family_members where user_id = tests.id('bob')),
  'nothing happens before approval');
select throws_ok(
  $$ select public.approve_request(tests.id('req')) $$,
  '42501', 'a second admin must approve', 'requester cannot approve own request'
);

select tests.login(tests.id('eve'));
select throws_ok(
  $$ select public.approve_request(tests.id('req')) $$,
  'P0002', null, 'admin of another family cannot approve'
);

select tests.login(tests.id('anna'), 'aal1');
select throws_ok(
  $$ select public.approve_request(tests.id('req')) $$,
  '28000', null, 'approving requires MFA'
);

select tests.login(tests.id('anna'));
select lives_ok($$ select public.approve_request(tests.id('req')) $$, 'second admin approves');
select tests.logout();
select ok(not exists (select 1 from public.family_members where family_id = tests.id('fam') and user_id = tests.id('bob')),
  'approved action is executed');
select tests.login(tests.id('anna'));
select throws_ok(
  $$ select public.approve_request(tests.id('req')) $$,
  '55000', 'request is not pending', 'executed request cannot be approved again'
);

-- ---- reject / cancel / expire --------------------------------------------------
select tests.login(tests.id('alice'));
select tests.set_id('req2', (public.request_action(tests.id('fam'), 'delete_family') ->> 'id')::uuid);
select tests.login(tests.id('anna'));
select lives_ok($$ select public.reject_request(tests.id('req2')) $$, 'other admin can reject');
select tests.logout();
select is((select status::text from public.approval_requests where id = tests.id('req2')), 'rejected', 'status is rejected');
select ok(exists (select 1 from public.families where id = tests.id('fam')), 'rejected delete did not delete the family');

select tests.login(tests.id('alice'));
select tests.set_id('req3', (public.request_action(tests.id('fam'), 'delete_family') ->> 'id')::uuid);
select tests.logout();
update public.approval_requests set expires_at = now() - interval '1 minute' where id = tests.id('req3');
select tests.login(tests.id('anna'));
select throws_ok(
  $$ select public.approve_request(tests.id('req3')) $$,
  '55000', 'request expired', 'expired requests cannot be approved'
);

select * from finish();
rollback;
