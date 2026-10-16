-- Verify the installed schema using existing users and synthetic data.
-- All test rows and keys are rolled back; no personal ledger is read or uploaded.
begin;
do $$
declare
  owner_user uuid; second_user uuid; account uuid := gen_random_uuid(); category uuid := gen_random_uuid();
  household uuid; invite text; phone1 jsonb; phone2 jsonb; event uuid := gen_random_uuid();
  result jsonb; envelope jsonb; pending_id uuid; snap jsonb;
begin
  select id into owner_user from auth.users where email_confirmed_at is not null order by created_at,id limit 1;
  select id into second_user from auth.users where email_confirmed_at is not null and id<>owner_user order by created_at,id limit 1;
  assert owner_user is not null and second_user is not null, 'Two confirmed users required';
  snap := jsonb_build_object('schemaVersion',4,
    'accounts',jsonb_build_array(jsonb_build_object('id',upper(account::text),'name','Temporary verification account','currency','USD','kind','checking','openingBalance',0,'color','green','archived',false)),
    'categories',jsonb_build_array(jsonb_build_object('id',upper(category::text),'name','Cafe','icon','cup.and.saucer','color','orange','kind','expense')),
    'transactions','[]'::jsonb,'budgets','[]'::jsonb,'goals','[]'::jsonb,'recurring','[]'::jsonb,'rules','[]'::jsonb,'imports','[]'::jsonb,
    'preferences',jsonb_build_object('baseCurrency','USD','rates',jsonb_build_object('USD',1),'appearance','system','automaticRates',false,'showBudgets',false,'showGoals',false,'showRecurring',false,'aiAgent','chatgpt'));
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',owner_user::text,true);
  envelope := public.mora_create_household('Temporary verification — rollback',snap);
  household := (envelope->>'household_id')::uuid;
  phone1 := public.mora_create_phone_token(household,account,'Temporary phone 1');
  invite := public.mora_create_invitation(household);
  perform set_config('request.jwt.claim.sub',second_user::text,true);
  assert not exists(select 1 from jsonb_array_elements(public.mora_list_households()) h where (h->>'id')::uuid=household), 'Uninvited user must not see the test household';
  begin
    perform public.mora_get_household(household);
    raise exception 'Uninvited access was allowed';
  exception when insufficient_privilege then null; end;
  result := public.mora_join_household(invite);
  assert (result->>'household_id')::uuid=household, 'Invitation join failed';
  assert not public.mora_revoke_phone_token((phone1->>'id')::uuid), 'Other user revoked a phone key';
  phone2 := public.mora_create_phone_token(household,account,'Temporary phone 2');
  execute 'set local role anon';
  perform set_config('request.jwt.claim.sub','',true);
  result := public.mora_capture_payment(phone1->>'token',event,'12.50','USD','Verification cafe',now());
  assert result->>'state'='recorded', 'First phone payment failed';
  result := public.mora_capture_payment(phone1->>'token',event,'12.50','USD','Verification cafe',now());
  assert (result->>'duplicate')::boolean, 'Duplicate protection failed';
  result := public.mora_capture_payment(phone2->>'token',gen_random_uuid(),'0.10','USD','Verification cafe',now());
  assert result->>'state'='recorded', 'Second phone payment failed';
  result := public.mora_capture_payment(phone2->>'token',gen_random_uuid(),'','USD','Verification cafe',now());
  assert result->>'state'='pending', 'Missing amount must go to inbox';
  pending_id := (result->>'id')::uuid;
  begin
    perform public.mora_capture_payment(repeat('0',64),gen_random_uuid(),'1','USD','Invalid key test',now());
    raise exception 'Invalid phone key was accepted';
  exception when insufficient_privilege then null; end;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',owner_user::text,true);
  envelope := public.mora_get_household(household);
  assert jsonb_array_length(envelope->'snapshot'->'transactions')=2, 'Incorrect payment count';
  assert ((envelope->'snapshot'->'transactions'->0->>'amount')::numeric+(envelope->'snapshot'->'transactions'->1->>'amount')::numeric)=-12.60, 'Decimal sum changed';
  assert not public.mora_save_household(household,1,snap), 'Stale desktop revision overwrote phone payments';
  result := public.mora_get_status(household);
  assert (result->>'version')::bigint=3 and (result->>'pending_count')::int=1, 'Revision marker incorrect';
  assert public.mora_resolve_capture(household,pending_id,account,'1.25','Verified amount',false), 'Inbox resolution failed';
  assert not public.mora_resolve_capture(household,pending_id,account,'1.25','Verified amount',false), 'Inbox resolved twice';
  assert jsonb_array_length(public.mora_list_pending(household))=0, 'Inbox not cleared';
  assert public.mora_revoke_phone_token((phone1->>'id')::uuid), 'Revocation failed';
  execute 'set local role anon';
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.mora_capture_payment(phone1->>'token',gen_random_uuid(),'1','USD','Revoked key test',now());
    raise exception 'Revoked phone key was accepted';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
select 'PASS: two users, invitation, two phones, Decimal, duplicate, inbox, CAS and revocation; all synthetic data rolled back' as verification;
