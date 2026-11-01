-- READ ONLY. Safe in Supabase production SQL editor.
-- Check the results manually: do not rely on a single PASS to prove authorisation.
select
 (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='expense_contributions' and c.relrowsecurity) as new_table_rls,
 (select count(*) from pg_policies where schemaname='public' and tablename='expense_contributions' and cmd='SELECT') as select_policies,
 has_table_privilege('authenticated','public.expense_contributions','SELECT') as member_can_read,
 has_table_privilege('authenticated','public.expense_contributions','INSERT,UPDATE,DELETE') as client_can_write,
 has_function_privilege('authenticated',
   'public.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)','EXECUTE') as authenticated_can_record,
 has_function_privilege('anon',
   'public.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)','EXECUTE') as anonymous_can_record,
 (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
  where c.relname in ('expenses','expense_contributions')
    and t.tgname like 'expense_funding_after_%' and not t.tgisinternal) as funding_triggers;
-- Expect: 1 / 1 / true / false / true / false / 2.

-- Every saved expense (including historical ones) must have exactly its bill in contributions.
select e.id,e.group_id,e.amount_paisa,coalesce(sum(c.amount_paisa),0) as contributions_paisa
from public.expenses e
left join public.expense_contributions c on c.expense_id=e.id
group by e.id,e.group_id,e.amount_paisa
having coalesce(sum(c.amount_paisa),0)<>e.amount_paisa;
-- Expect: zero rows.

-- Contributions and shares always balance at the group level (voided sessions excluded).
with amounts as (
 select e.group_id, sum(c.amount_paisa) as contributions
 from public.expenses e join public.expense_contributions c on c.expense_id=e.id
 where e.voided_at is null group by e.group_id
), shares as (
 select e.group_id, sum(s.share_paisa) as consumed
 from public.expenses e join public.expense_shares s on s.expense_id=e.id
 where e.voided_at is null group by e.group_id
)
select coalesce(a.group_id,s.group_id) group_id, a.contributions,s.consumed
from amounts a full join shares s using (group_id)
where a.contributions is distinct from s.consumed;
-- Expect: zero rows.
