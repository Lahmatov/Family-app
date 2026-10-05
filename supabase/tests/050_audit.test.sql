-- Audit log: written by the system, readable by admins, immutable for everyone.
begin;
select plan(9);

select tests.set_id('alice', tests.create_user('alice@example.com'));
select tests.set_id('bob',   tests.create_user('bob@example.com'));
select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');

select tests.login(tests.id('alice'));
select public.request_action(tests.id('fam'), 'invite_member', '{"email":"nina@example.com","role":"adult"}');

select ok(
  (select array_agg(action order by id) from public.audit_log where family_id = tests.id('fam'))
    @> array['family.created', 'approval.requested', 'approval.auto_executed'],
  'critical actions are audited'
);
select is(
  (select actor_id from public.audit_log where action = 'approval.requested' and family_id = tests.id('fam')),
  tests.id('alice'), 'audit records the actor'
);
select throws_ok($$ delete from public.audit_log $$, '42501', null, 'admin cannot delete audit entries');
select throws_ok($$ update public.audit_log set action = 'x' $$, '42501', null, 'admin cannot edit audit entries');

select tests.login(tests.id('bob'));
select is((select count(*)::int from public.audit_log), 0, 'non-admins cannot read the audit log');

select tests.logout();
select throws_ok($$ update public.audit_log set action = 'x' $$, '42501', 'audit_log is append-only', 'audit log is append-only even for the table owner');

select throws_ok($$ delete from public.audit_log $$, '42501', 'audit_log is append-only', 'audit rows cannot be deleted while the family exists');

-- Deleting the family (single admin -> executes immediately) cascades cleanly.
select tests.login(tests.id('alice'));
select is(public.request_action(tests.id('fam'), 'delete_family') ->> 'status', 'executed', 'single admin deletes family');
select tests.logout();
select ok(not exists (select 1 from public.families where id = tests.id('fam'))
  and not exists (select 1 from public.audit_log where family_id = tests.id('fam')),
  'family and its audit trail are gone');

select * from finish();
rollback;
