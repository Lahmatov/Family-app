-- Family tasks and their discussion: members (children too) work together, guests and outsiders see nothing.
begin;
select plan(17);

select tests.set_id('alice', tests.create_user('alice@example.com'));  -- admin
select tests.set_id('bob',   tests.create_user('bob@example.com'));    -- adult
select tests.set_id('teen',  tests.create_user('teen@example.com'));   -- child
select tests.set_id('gran',  tests.create_user('gran@example.com'));   -- guest
select tests.set_id('eve',   tests.create_user('eve@example.com'));    -- other family

select tests.set_id('fam', tests.create_family(tests.id('alice')));
select tests.set_id('evefam', tests.create_family(tests.id('eve'), 'Eve family'));
select tests.add_member(tests.id('fam'), tests.id('bob'), 'adult');
select tests.add_member(tests.id('fam'), tests.id('teen'), 'child');
select tests.add_member(tests.id('fam'), tests.id('gran'), 'guest');

select tests.login(tests.id('bob'));
select lives_ok($$ insert into public.tasks (family_id, title, assignee_id, due_on)
  values (tests.id('fam'), 'Renew passports', tests.id('teen'), current_date + 30) $$, 'adult creates and assigns a task');
select tests.set_id('t1', (select id from public.tasks where title = 'Renew passports'));

select throws_ok($$ insert into public.tasks (family_id, title, assignee_id) values (tests.id('fam'), 'Wrong assignee', tests.id('eve')) $$,
  '23503', null, 'the assignee must belong to the family');
select throws_ok($$ insert into public.tasks (family_id, title) values (tests.id('fam'), '   ') $$, '23514', null, 'a blank title is rejected');

select tests.login(tests.id('teen'));
select is((select count(*)::int from public.tasks), 1, 'a child sees family tasks');
select lives_ok($$ update public.tasks set status = 'doing' where id = tests.id('t1') $$, 'and moves them along');
select lives_ok($$ insert into public.task_comments (task_id, family_id, body) values (tests.id('t1'), tests.id('fam'), 'Photos are done') $$, 'and discusses them');
select lives_ok($$ insert into public.tasks (family_id, title) values (tests.id('fam'), 'Tidy my room') $$, 'a child can add a chore');

select tests.login(tests.id('alice'));
select is((select count(*)::int from public.task_comments where task_id = tests.id('t1')), 1, 'everyone sees the discussion');
select lives_ok($$ update public.tasks set status = 'done' where id = tests.id('t1') $$, 'done');
select isnt((select done_at from public.tasks where id = tests.id('t1')), null, 'completion time is set by the database');
select lives_ok($$ update public.tasks set status = 'todo' where id = tests.id('t1') $$, 'reopened');
select is((select done_at from public.tasks where id = tests.id('t1')), null, 'and cleared again');
select throws_ok($$ update public.tasks set created_by = tests.id('alice') where id = tests.id('t1') $$, '42501', null, 'the author cannot be rewritten');

select tests.login(tests.id('gran'));
select is((select count(*)::int from public.tasks) + (select count(*)::int from public.task_comments), 0, 'a guest sees nothing');
select tests.login(tests.id('eve'));
select is((select count(*)::int from public.tasks) + (select count(*)::int from public.task_comments), 0, 'an outsider sees nothing');

select tests.login(tests.id('teen'));
delete from public.tasks where id = tests.id('t1');
select tests.logout();
select is((select count(*)::int from public.tasks where id = tests.id('t1')), 1, 'a child cannot delete someone else''s task');

-- leaving the family leaves the task unassigned instead of blocking or deleting it
delete from public.family_members where family_id = tests.id('fam') and user_id = tests.id('teen');
select is((select assignee_id from public.tasks where id = tests.id('t1')), null, 'when the assignee leaves, the task is unassigned');

select * from finish();
rollback;
