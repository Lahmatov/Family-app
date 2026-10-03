-- Regression tests for findings of the security review.
begin;
select plan(4);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin, will lose the role
select tests.set_id('anna',  tests.create_user('anna@example.com'));   -- second admin
select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.add_member(tests.id('fam'), tests.id('anna'), 'admin');

-- Finding 1: a request made by someone who is no longer an admin must not be approvable.
select tests.login(tests.id('alice'));
select tests.set_id('req', (public.request_action(tests.id('fam'), 'invite_member',
  '{"email":"mallory@example.com","role":"admin"}') ->> 'id')::uuid);
select tests.logout();
update public.family_members set role = 'adult' where family_id = tests.id('fam') and user_id = tests.id('alice');  -- demoted
select tests.login(tests.id('anna'));
select throws_ok($$ select public.approve_request(tests.id('req')) $$, '55000', 'requester is no longer an admin',
  'request of a demoted admin cannot be approved');
select tests.logout();
select is((select count(*)::int from public.family_invitations where email = 'mallory@example.com'), 0,
  'nothing was executed');

-- Guard: API roles never get table-wide INSERT/UPDATE (column grants only, no mass assignment).
select is(
  (select array_agg(c.relname::text order by c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
     and (has_table_privilege('authenticated', c.oid, 'INSERT') or has_table_privilege('authenticated', c.oid, 'UPDATE'))),
  null, 'authenticated has no table-level INSERT/UPDATE anywhere');

select is(
  (select array_agg(c.relname::text order by c.relname)
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
     and has_table_privilege('authenticated', c.oid, 'REFERENCES')),
  null, 'authenticated has no REFERENCES/TRIGGER style extras');

select * from finish();
rollback;
