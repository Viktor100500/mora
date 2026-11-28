begin;
do $$
declare h uuid; owner_id uuid; a uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); snap jsonb;
  phone jsonb; wallet jsonb; bank jsonb; early jsonb; late jsonb; other jsonb; result jsonb;
  tx jsonb; event uuid:=gen_random_uuid(); before_count integer; rejected boolean;
begin
  select hh.owner_id into owner_id from public.mora_households hh limit 1;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  snap:=jsonb_build_object('schemaVersion',4,'accounts',jsonb_build_array(
    jsonb_build_object('id',upper(a::text),'name','Synthetic EUR','currency','EUR','kind','checking','openingBalance',0,'color','green','archived',false),
    jsonb_build_object('id',upper(r::text),'name','Synthetic RSD','currency','RSD','kind','checking','openingBalance',0,'color','green','archived',false)),
    'categories','[]'::jsonb,'transactions','[]'::jsonb,'budgets','[]'::jsonb,'goals','[]'::jsonb,'recurring','[]'::jsonb,'rules','[]'::jsonb,'imports','[]'::jsonb,
    'preferences',jsonb_build_object('baseCurrency','EUR','rates',jsonb_build_object('EUR',1,'RSD',0.0085),'appearance','system','automaticRates',false,
      'showBudgets',false,'showGoals',false,'showRecurring',false,'aiAgent','chatgpt'));
  result:=public.mora_create_household('Synthetic Wallet regression; rolled back',snap);
  h:=(result->>'household_id')::uuid;
  phone:=public.mora_create_phone_token(h,a,'Synthetic phone');
  wallet:=public.mora_capture_payment_from_source(phone->>'token',event,'3','USD','Metropolitan Transportation Authority','2026-11-24T18:40:22Z','Visa Debit','wallet_transaction');
  tx:=jsonb_build_object('id',upper(gen_random_uuid()::text),'date','2026-11-24T18:40:22Z','merchant','Metropolitan Transportation Authority','amount',-2.70,
    'accountID',upper(a::text),'kind','expense','note','','tags','[]'::jsonb,
    'conversion',jsonb_build_object('originalAmount',-3,'originalCurrency','USD','accountCurrency','EUR','rate',0.9,'date','2026-11-24T00:00:00Z','provider','Visa'));
  result:=public.mora_review_capture(h,(wallet->>'id')::uuid,tx);
  before_count:=jsonb_array_length(result->'snapshot'->'transactions');
  bank:=public.mora_capture_payment_from_source(phone->>'token',gen_random_uuid(),'3','USD','MTA*NYCT PAYGO NEW YORK','2026-11-24T18:40:37Z','Bank app ··5109','bank_notification');
  if bank->>'state'<>'duplicate' then raise exception 'Wallet-first duplicate missed: %',bank; end if;
  result:=public.mora_review_capture(h,(bank->>'id')::uuid,tx);
  if jsonb_array_length(result->'snapshot'->'transactions')<>before_count then raise exception 'Stale review appended a duplicate'; end if;
  other:=public.mora_capture_payment_from_source(phone->>'token',gen_random_uuid(),'3','USD','MTA*NYCT PAYGO NEW YORK','2026-11-24T18:40:38Z','Bank app ··5109','bank_notification');
  if other->>'state'<>'pending' then raise exception 'Second same-channel purchase swallowed'; end if;
  result:=public.mora_capture_payment_from_source(phone->>'token',event,'3','USD','Metropolitan Transportation Authority','2026-11-24T18:40:22Z','Visa Debit','wallet_transaction');
  if result->>'id'<>wallet->>'id' or result->>'state'<>'recorded' then raise exception 'Idempotent retry differs'; end if;
  -- Reverse arrival order, with the PATH processor and Wallet display-name alias.
  early:=public.mora_capture_payment_from_source(phone->>'token',gen_random_uuid(),'3.25','USD','PATH TAPP PAYGO CP JERSEY CITY','2026-11-24T19:00:07Z','Bank app ··5109','bank_notification');
  late:=public.mora_capture_payment_from_source(phone->>'token',gen_random_uuid(),'3.25','USD','Port Authority of New York & New Jersey','2026-11-24T19:00:00Z','Visa Debit','wallet_transaction');
  tx:=jsonb_set(tx,'{date}','"2026-11-24T19:00:00Z"');
  tx:=jsonb_set(tx,'{merchant}','"Port Authority of New York & New Jersey"');
  tx:=jsonb_set(tx,'{amount}','-2.93');
  tx:=jsonb_set(tx,'{conversion,originalAmount}','-3.25');
  result:=public.mora_review_capture(h,(late->>'id')::uuid,tx);
  if (select state from public.mora_captures where id=(early->>'id')::uuid)<>'duplicate' then raise exception 'Bank-first duplicate missed'; end if;
  -- An installed older client recovers sources from the exact known card alias.
  wallet:=public.mora_capture_payment(phone->>'token',gen_random_uuid(),'8.50','USD','Chapel Deli & Market','2026-11-24T19:30:00Z','Visa Debit');
  if (select capture_source from public.mora_captures where id=(wallet->>'id')::uuid)<>'wallet_transaction' then raise exception 'Legacy Wallet source not recovered'; end if;
  tx:=jsonb_set(tx,'{date}','"2026-11-24T19:30:00Z"');
  tx:=jsonb_set(tx,'{merchant}','"Chapel Deli & Market"');
  tx:=jsonb_set(tx,'{amount}','-7.65');
  tx:=jsonb_set(tx,'{conversion,originalAmount}','-8.5');
  perform public.mora_review_capture(h,(wallet->>'id')::uuid,tx);
  bank:=public.mora_capture_payment(phone->>'token',gen_random_uuid(),'8.50','USD','CHAPEL DELI Brooklyn','2026-11-24T19:30:12Z','Bank app ··5109');
  if bank->>'state'<>'duplicate' then raise exception 'Legacy bank source not reconciled'; end if;
  if (select capture_source from public.mora_captures where id=(bank->>'id')::uuid)<>'bank_notification' then raise exception 'Legacy bank source not recovered'; end if;
  other:=public.mora_capture_payment(phone->>'token',gen_random_uuid(),'8.50','USD','Chapel Deli','2026-11-24T19:30:14Z','Unknown card');
  if other->>'state'<>'pending' or (select capture_source from public.mora_captures where id=(other->>'id')::uuid)<>'legacy' then raise exception 'Unknown card inherited a source'; end if;
  -- The previous API remains callable by installed older clients.
  result:=public.mora_capture_payment(phone->>'token',gen_random_uuid(),'5','USD','Legacy store','2026-11-24T20:00:00Z','Bank app ··5109');
  if result->>'state'<>'pending' then raise exception 'Legacy endpoint changed'; end if;
  -- RSD must preserve two digits; display-rounded whole dinars must be rejected.
  phone:=public.mora_create_phone_token(h,r,'Synthetic RSD phone');
  wallet:=public.mora_capture_payment_from_source(phone->>'token',gen_random_uuid(),'3','USD','RSD precision','2026-11-24T21:00:00Z','','wallet_transaction');
  tx:=jsonb_build_object('id',upper(gen_random_uuid()::text),'date','2026-11-24T21:00:00Z','merchant','RSD precision','amount',-322.43,
    'accountID',upper(r::text),'kind','expense','note','','tags','[]'::jsonb,
    'conversion',jsonb_build_object('originalAmount',-3,'originalCurrency','USD','accountCurrency','RSD','rate',107.477244,'date','2026-11-24T00:00:00Z','provider','Visa'));
  rejected:=false;
  begin perform public.mora_review_capture(h,(wallet->>'id')::uuid,jsonb_set(tx,'{amount}','-322'));
  exception when others then rejected:=true; end;
  if not rejected then raise exception 'Whole-dinar rounding accepted'; end if;
  result:=public.mora_review_capture(h,(wallet->>'id')::uuid,tx);
  if not exists(select 1 from jsonb_array_elements(result->'snapshot'->'transactions') t where (t->>'id')::uuid=(wallet->>'id')::uuid and (t->>'amount')::numeric=-322.43) then
    raise exception 'RSD precision differs'; end if;
  if public.mora_currency_decimals('RSD')<>2 or public.mora_currency_decimals('JPY')<>0 or public.mora_currency_decimals('KWD')<>3 then raise exception 'Currency contract differs'; end if;
  rejected:=false;
  begin perform public.mora_capture_payment_from_source(repeat('0',64),gen_random_uuid(),'3','USD','Invalid','2026-11-24T21:00:00Z','','wallet_transaction');
  exception when insufficient_privilege then rejected:=true; end;
  if not rejected then raise exception 'Invalid phone key accepted'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  rejected:=false;
  begin perform public.mora_get_household(h); exception when insufficient_privilege then rejected:=true; end;
  if not rejected then raise exception 'Anonymous household access accepted'; end if;
  if has_function_privilege('anon','public.mora_wallet_duplicate_transaction(public.mora_captures,jsonb)','execute') then raise exception 'Private helper exposed'; end if;
end $$;
rollback;
select 'Passed: source pairing in both orders, transit aliases, same-channel preservation, stale-review safety, event idempotency, legacy API, RSD precision and access checks. All synthetic data rolled back.' result;
