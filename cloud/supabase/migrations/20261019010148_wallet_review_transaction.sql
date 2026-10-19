-- A reviewed Wallet purchase uses the same complete transaction as the editor.
-- Booking and removing it from the inbox commit together under the household lock.
begin;
create function public.mora_review_capture(p_household_id uuid, p_capture_id uuid, p_transaction jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.mora_captures; snap jsonb; tx jsonb; account jsonb; destination jsonb; category jsonb;
  amount numeric; credited numeric; occurred timestamptz; conversion jsonb;
  original numeric; rate numeric; fee numeric; decimals integer;
begin
  perform public.mora_require_member(p_household_id);
  select snapshot into snap from public.mora_households where id=p_household_id for update;
  select * into c from public.mora_captures where id=p_capture_id and household_id=p_household_id for update;
  if c.id is null then raise exception 'Capture missing'; end if;
  -- A lost response or two reviewers must never append a second transaction.
  if c.state='recorded' then return public.mora_envelope(p_household_id); end if;
  if c.state<>'pending' then raise exception 'Capture no longer pending'; end if;
  if jsonb_typeof(p_transaction) is distinct from 'object' or octet_length(p_transaction::text)>64000 then
    raise exception 'Invalid transaction';
  end if;
  tx := p_transaction;
  if exists(select 1 from jsonb_object_keys(tx) k where k <> all(array[
    'id','date','merchant','amount','accountID','kind','note','tags','categoryID',
    'destinationAccountID','destinationAmount','externalID','conversion'])) then raise exception 'Unsupported transaction fields'; end if;
  if tx->>'kind' not in ('expense','income','transfer') or tx->>'kind' is null
    or jsonb_typeof(tx->'amount') is distinct from 'number'
    or jsonb_typeof(tx->'merchant') is distinct from 'string' or length(trim(tx->>'merchant')) not between 1 and 2000
    or jsonb_typeof(tx->'note') is distinct from 'string' or length(tx->>'note')>10000
    or jsonb_typeof(tx->'tags') is distinct from 'array'
    or jsonb_typeof(tx->'date') is distinct from 'string' then raise exception 'Invalid transaction fields'; end if;
  if jsonb_array_length(tx->'tags')>100 or exists(select 1 from jsonb_array_elements(tx->'tags') tag
    where jsonb_typeof(tag)<>'string' or length(tag#>>'{}')>100) then raise exception 'Invalid tags'; end if;
  amount := (tx->>'amount')::numeric;
  occurred := (tx->>'date')::timestamptz;
  if amount=0 or abs(amount)>999999999999 or not isfinite(occurred)
    or (tx->>'kind'='income' and amount<0) or (tx->>'kind'<>'income' and amount>0) then raise exception 'Invalid amount or date'; end if;
  select a into account from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=(tx->>'accountID')::uuid;
  if account is null or coalesce((account->>'archived')::boolean,false) then raise exception 'Account missing or archived'; end if;
  if nullif(tx->>'categoryID','') is not null then
    select cat into category from jsonb_array_elements(snap->'categories') cat where (cat->>'id')::uuid=(tx->>'categoryID')::uuid;
    if category is null or category->>'kind'<>tx->>'kind' or tx->>'kind'='transfer' then raise exception 'Invalid category'; end if;
  end if;
  if tx->>'kind'='transfer' then
    select a into destination from jsonb_array_elements(snap->'accounts') a where (a->>'id')::uuid=(tx->>'destinationAccountID')::uuid;
    if destination is null or destination->>'id'=account->>'id' or coalesce((destination->>'archived')::boolean,false)
      or jsonb_typeof(tx->'destinationAmount') is distinct from 'number' then raise exception 'Invalid transfer destination'; end if;
    credited := (tx->>'destinationAmount')::numeric;
    if credited<=0 or (destination->>'currency'=account->>'currency' and credited<>-amount) then raise exception 'Invalid transfer amount'; end if;
  elsif tx->>'destinationAccountID' is not null or tx->>'destinationAmount' is not null then
    raise exception 'Unexpected transfer fields';
  end if;
  conversion := tx->'conversion';
  if conversion is not null and conversion<>'null'::jsonb then
    if tx->>'kind'='transfer' or jsonb_typeof(conversion) is distinct from 'object'
      or conversion->>'accountCurrency' is distinct from account->>'currency'
      or coalesce(conversion->>'originalCurrency','') !~ '^[A-Z]{3}$'
      or conversion->>'originalCurrency'=account->>'currency'
      or jsonb_typeof(conversion->'originalAmount') is distinct from 'number'
      or jsonb_typeof(conversion->'rate') is distinct from 'number'
      or conversion->>'provider' is distinct from 'Visa'
      or conversion->>'date' is null then raise exception 'Invalid conversion'; end if;
    original := (conversion->>'originalAmount')::numeric;
    rate := (conversion->>'rate')::numeric;
    fee := coalesce((conversion->>'bankFeePercent')::numeric,0);
    if original*amount<=0 or rate<=0 or fee<0 or fee>100 or (original>0 and fee<>0)
      or not isfinite((conversion->>'date')::timestamptz) then raise exception 'Invalid conversion values'; end if;
    decimals := case when account->>'currency'=any(array['BIF','CLP','DJF','GNF','ISK','JPY','KMF','KRW','PYG','RWF','UGX','UYI','VND','VUV','XAF','XOF','XPF']) then 0
      when account->>'currency'=any(array['BHD','IQD','JOD','KWD','LYD','OMR','TND']) then 3
      when account->>'currency'=any(array['CLF','UYW']) then 4 else 2 end;
    if round(original*rate*(1+fee/100),decimals)<>amount then raise exception 'Converted amount differs'; end if;
  end if;
  if exists(select 1 from jsonb_array_elements(snap->'transactions') t
    where (t->>'id')::uuid=c.id or t->>'externalID'='wallet:'||c.id::text) then raise exception 'Wallet transaction already exists'; end if;
  tx := tx || jsonb_build_object('id',upper(c.id::text),'externalID','wallet:'||c.id::text,
                                'accountID',upper((tx->>'accountID')::uuid::text));
  snap := jsonb_set(snap,'{transactions}',(snap->'transactions')||jsonb_build_array(tx));
  perform public.mora_validate_snapshot(snap);
  update public.mora_households set snapshot=snap,version=version+1,updated_at=now() where id=p_household_id;
  update public.mora_captures set state='recorded',transaction_id=c.id,reason=null where id=c.id;
  return public.mora_envelope(p_household_id);
end $$;
revoke all on function public.mora_review_capture(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.mora_review_capture(uuid,uuid,jsonb) to authenticated;
commit;
