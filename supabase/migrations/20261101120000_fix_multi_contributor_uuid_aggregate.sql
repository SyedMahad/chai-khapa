-- Chai Khapa Phase 3.8.2: Fix PostgreSQL 42883 on multi-contributor saves.
-- The Phase 3.8 backend used min(uuid), unsupported by older PostgreSQL releases.
-- Keep original function signature, owner, SECURITY DEFINER and fixed search_path.
-- No table changes and no modifications to existing financial records.
-- Apply AFTER 20261101050000_multiple_expense_contributors.sql.

begin;

-- Fail closed if the required earlier migration is missing.
do $$ begin
  if to_regprocedure('app_private.record_expense_multi(uuid,bigint,uuid[],uuid[],bigint[],uuid,text,timestamptz)') is null then
    raise exception 'Phase 3.8 record_expense_multi is missing; apply prior migration first';
  end if;
end $$;

create or replace function app_private.record_expense_multi(
 p_group_id uuid,p_amount_paisa bigint,p_participant_user_ids uuid[],
 p_contributor_user_ids uuid[],p_contribution_amounts_paisa bigint[],
 p_request_id uuid,p_description text default null,p_occurred_at timestamptz default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare
 v_actor uuid:=auth.uid(); v_group public.groups%rowtype; v_expense_id uuid;
 v_existing public.expenses%rowtype; v_occurs timestamptz:=coalesce(p_occurred_at,now());
 v_desc text:=nullif(btrim(p_description),'');
 v_n int; v_cn int; v_member_count int; v_contributor_count int;
 v_primary uuid; v_name text;
begin
 if v_actor is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if p_group_id is null or p_request_id is null or p_amount_paisa is null or p_amount_paisa<=0 then
   raise exception 'Group, positive bill and request ID required' using errcode='22023'; end if;
 if v_desc is not null and char_length(v_desc)>240 then
   raise exception 'Session description too long' using errcode='22023'; end if;
 if v_occurs>now()+interval '5 minutes' or v_occurs<now()-interval '31 days' then
   raise exception 'Session date must be within 31 days and not future' using errcode='22023'; end if;

 -- Serializes writes with month closing and concurrent attempts to use one request ID.
 select * into v_group from public.groups where id=p_group_id for update;
 if not found or v_group.archived_at is not null then
   raise exception 'Group missing or archived' using errcode='22023'; end if;
 if not exists (select 1 from public.group_members gm where gm.group_id=p_group_id
   and gm.user_id=v_actor and gm.left_at is null) then
   raise exception 'Only active group members may record expenses' using errcode='42501'; end if;

 v_n:=coalesce(cardinality(p_participant_user_ids),0);
 v_cn:=coalesce(cardinality(p_contributor_user_ids),0);
 if v_n<1 or v_cn<1 or v_n>100 or v_cn>100
    or v_cn<>coalesce(cardinality(p_contribution_amounts_paisa),0) then
   raise exception 'Select attendees and 1–100 contributors with matching amounts' using errcode='22023'; end if;
 if exists(select 1 from unnest(p_participant_user_ids) a(id) where a.id is null)
    or (select count(distinct a.id) from unnest(p_participant_user_ids) a(id))<>v_n
    or exists(select 1 from unnest(p_contributor_user_ids) a(id) where a.id is null)
    or (select count(distinct a.id) from unnest(p_contributor_user_ids) a(id))<>v_cn then
   raise exception 'Attendees and contributors must be unique valid users' using errcode='22023'; end if;
 if exists(select 1 from unnest(p_contribution_amounts_paisa) a(amount) where a.amount is null or a.amount<=0)
    or (select coalesce(sum(a.amount),0) from unnest(p_contribution_amounts_paisa) a(amount))<>p_amount_paisa::numeric then
   raise exception 'Contributions must be positive and equal the full bill' using errcode='22023'; end if;
 select count(*) into v_member_count from public.group_members gm
   where gm.group_id=p_group_id and gm.left_at is null and gm.user_id=any(p_participant_user_ids);
 select count(*) into v_contributor_count from public.group_members gm
   where gm.group_id=p_group_id and gm.left_at is null and gm.user_id=any(p_contributor_user_ids);
 if v_member_count<>v_n or v_contributor_count<>v_cn then
   raise exception 'Every attendee and contributor must be an active group member' using errcode='22023'; end if;

 v_primary:=case when v_actor=any(p_contributor_user_ids) then v_actor
  else (select c.user_id from unnest(p_contributor_user_ids) c(user_id) order by c.user_id limit 1) end;
 select * into v_existing from public.expenses e where e.created_by_user_id=v_actor and e.request_id=p_request_id;
 if found then
   if v_existing.group_id<>p_group_id or v_existing.amount_paisa<>p_amount_paisa
      or v_existing.paid_by_user_id<>v_primary or v_existing.description is distinct from v_desc
      or (p_occurred_at is not null and v_existing.occurred_at<>p_occurred_at)
      or v_existing.voided_at is not null
      or (select array_agg(s.user_id order by s.user_id) from public.expense_shares s where s.expense_id=v_existing.id)
         is distinct from (select array_agg(u.user_id order by u.user_id) from unnest(p_participant_user_ids) u(user_id))
      or (select jsonb_agg(jsonb_build_array(c.user_id,c.amount_paisa) order by c.user_id)
         from public.expense_contributions c where c.expense_id=v_existing.id)
         is distinct from (select jsonb_agg(jsonb_build_array(u.user_id,u.amount) order by u.user_id)
         from unnest(p_contributor_user_ids,p_contribution_amounts_paisa) u(user_id,amount)) then
       raise exception 'Request ID already used for a different bill' using errcode='23505'; end if;
   return v_existing.id;
 end if;

 -- Already saved retries remain valid after a month is closed.
 if exists (select 1 from public.settlement_periods sp where sp.group_id=p_group_id
  and v_occurs>=sp.start_at and v_occurs<sp.end_at) then
   raise exception 'This accounting month is closed' using errcode='22023'; end if;

 insert into public.expenses(group_id,created_by_user_id,paid_by_user_id,amount_paisa,
  split_method,occurred_at,description,request_id)
 values(p_group_id,v_actor,v_primary,p_amount_paisa,'equal',v_occurs,v_desc,p_request_id)
 returning id into v_expense_id;

 insert into public.expense_contributions(expense_id,group_id,user_id,amount_paisa)
 select v_expense_id,p_group_id,u.user_id,u.amount
 from unnest(p_contributor_user_ids,p_contribution_amounts_paisa) u(user_id,amount);
 insert into public.expense_shares(expense_id,group_id,user_id,share_paisa)
 select v_expense_id,p_group_id,u.user_id,
   (p_amount_paisa/v_n)::bigint + case when u.ordinal<=(p_amount_paisa%v_n) then 1 else 0 end
 from (select p.user_id,row_number() over(order by p.user_id) ordinal
   from unnest(p_participant_user_ids) p(user_id)) u;

 insert into public.expense_audit(expense_id,group_id,actor_user_id,operation,after_json)
 values(v_expense_id,p_group_id,v_actor,'created',jsonb_build_object(
  'amount_paisa',p_amount_paisa,'occurred_at',v_occurs,'split_method','equal',
  'participants',(select jsonb_agg(jsonb_build_object('user_id',s.user_id,'share_paisa',s.share_paisa) order by s.user_id)
    from public.expense_shares s where s.expense_id=v_expense_id),
  'contributors',(select jsonb_agg(jsonb_build_object('user_id',c.user_id,'amount_paisa',c.amount_paisa) order by c.user_id)
    from public.expense_contributions c where c.expense_id=v_expense_id)));

 select coalesce(nullif(btrim(p.first_name||' '||p.last_name),''),'A colleague')
   into v_name from public.profiles p where p.user_id=v_actor;
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 select s.user_id,p_group_id,'expense:'||v_expense_id::text||':created',
   'expense_created','New chai session',
   coalesce(v_name,'A colleague')||' recorded a session. Your share: Rs. '
    ||(s.share_paisa/100)::text||'.'||lpad((s.share_paisa%100)::text,2,'0')||'.',
   'expense',v_expense_id
 from public.expense_shares s where s.expense_id=v_expense_id and s.user_id<>v_actor
 on conflict(recipient_user_id,event_key) do nothing;
 -- Include contributors who weren't attendees, so they can see their credited contribution.
 insert into public.notifications(recipient_user_id,group_id,event_key,type,title,body,target_type,target_id)
 select c.user_id,p_group_id,'expense:'||v_expense_id::text||':contributed',
   'expense_created','Your contribution was recorded',
   coalesce(v_name,'A colleague')||' recorded your contribution of Rs. '
    ||(c.amount_paisa/100)::text||'.'||lpad((c.amount_paisa%100)::text,2,'0')||'.',
   'expense',v_expense_id
 from public.expense_contributions c where c.expense_id=v_expense_id and c.user_id<>v_actor
   and not exists (select 1 from public.expense_shares s where s.expense_id=v_expense_id and s.user_id=c.user_id)
 on conflict(recipient_user_id,event_key) do nothing;
 return v_expense_id;
end $$;


commit;
